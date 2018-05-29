open Lwt.Infix

(** Common signature for http and https. *)
module type HTTP_SERVER = Cohttp_lwt.S.Server

(* Logging *)
let https_src = Logs.Src.create "https" ~doc:"HTTPS server"
module Https_log = (val Logs.src_log https_src : Logs.LOG)

let http_src = Logs.Src.create "http" ~doc:"HTTP server"
module Http_log = (val Logs.src_log http_src : Logs.LOG)

module Dispatch
    (FS: Mirage_types_lwt.KV_RO)
    (Serv: HTTP_SERVER)
    (KR: S.Keyring)
    (Clock: Webmachine.CLOCK)
= struct

  module API = Api.Dispatch(Serv)(KR)(Clock)

  let failf fmt = Fmt.kstrf Lwt.fail_with fmt

  (* a convenience function for getting the full contents
   * of the file at a given path from the file system. *)
  let read_whole_file fs name =
    FS.size fs name >>= function
    | Error e -> failf "size: %a" FS.pp_error e
    | Ok size ->
      FS.read fs name 0L size >>= function
      | Error e -> failf "read: %a" FS.pp_error e
      | Ok bufs -> Lwt.return (Cstruct.copyv bufs)

  let starts_with s1 s2 =
    let len1 = String.length s1
    and len2 = String.length s2 in
    if len1 < len2 then false else
      let sub = String.sub s1 0 len2 in
      (sub = s2)

  (* given a URI, find the appropriate file,
   * and construct a response with its contents. *)
  let rec dispatch_file fs uri =
    match Uri.path uri with
    | "" | "/" -> dispatch_file fs (Uri.with_path uri "index.html")
    | path ->
      let header =
        Cohttp.Header.init_with "Strict-Transport-Security" "max-age=31536000"
      in
      let mimetype = Magic_mime.lookup path in
      let headers = Cohttp.Header.add header "content-type" mimetype in
      Lwt.catch
        (fun () ->
           read_whole_file fs path >>= fun body ->
           Serv.respond_string ~status:`OK ~body ~headers ())
        (fun _exn ->
           Serv.respond_not_found ())

  let dispatcher fs keyring request body =
    let uri = Cohttp.Request.uri request in
    if starts_with (Uri.path uri) "/api/" then
      API.dispatcher keyring request body
    else
      dispatch_file fs uri

  (* Redirect to the same address, but in https. *)
  let redirect port request _body =
    let uri = Cohttp.Request.uri request in
    let new_uri = Uri.with_scheme uri (Some "https") in
    let new_uri = Uri.with_port new_uri (Some port) in
    Http_log.info (fun f -> f "[%s] -> [%s]"
                      (Uri.to_string uri) (Uri.to_string new_uri)
                  );
    let headers = Cohttp.Header.init_with "location" (Uri.to_string new_uri) in
    Serv.respond ~headers ~status:`Moved_permanently ~body:`Empty ()

  let serve dispatch =
    let callback (_, cid) request body =
      let uri = Cohttp.Request.uri request in
      let cid = Cohttp.Connection.to_string cid in
      Https_log.info (fun f -> f "[%s] serving %s." cid (Uri.to_string uri));
      dispatch request body
    in
    let conn_closed (_,cid) =
      let cid = Cohttp.Connection.to_string cid in
      Https_log.info (fun f -> f "[%s] closing" cid);
    in
    Serv.make ~conn_closed ~callback ()

end

module Main
    (Pclock: Mirage_types.PCLOCK)
    (Data: Mirage_types_lwt.KV_RO)
    (Certs: Mirage_types_lwt.KV_RO)
    (Stack: Mirage_types_lwt.STACKV4)
    (Con: Conduit_mirage.S)
= struct

  module X509 = Tls_mirage.X509(Certs)(Pclock)
  module Http_srv = Cohttp_mirage.Server_with_conduit

  let tls_init kv =
    X509.certificate kv `Default >>= fun cert ->
    let conf = Tls.Config.server ~certificates:(`Single cert) () in
    Lwt.return conf

  let start clock data certs stack con =
    let module Res = Resolver_mirage.Make_with_stack(OS.Time)(Stack) in
    let nameserver = match Ipaddr.V4.of_string @@ Key_gen.nameserver () with
      | None -> Ipaddr.V4.make 8 8 8 8
      | Some ip -> ip
    in
    let res_dns = Res.R.init ~ns:nameserver ~stack:stack () in
    let module Client =
    struct
      include Cohttp_mirage.Client
      let call ?ctx:_ = call ~ctx:(ctx res_dns con)
    end
    in
    let irmin_url = Key_gen.irmin_url () in
    let (
      (module KV: Irmin.KV_MAKER),
      storage_config
    ) = match irmin_url with
      | "" -> (
        (module Irmin_mem.KV : Irmin.KV_MAKER),
        Irmin_mem.config ()
      )
      | url -> (
        (module Irmin_http.KV(Client) : Irmin.KV_MAKER),
        Irmin_http.config (Uri.of_string url)
      )
    in
    let masterkey = Cstruct.of_hex (Key_gen.masterkey ()) in
    let (module Enc : S.Encryptor) = match (Cstruct.len masterkey) with 
      | 0 ->
        Logs.warn (fun f -> f "*** No masterkey provided! Storage is unencrypted! ***");
        (module Encryptor.Null : S.Encryptor)
      | _ ->
        (module Encryptor.Make(struct let key = masterkey end) : S.Encryptor)
    in
    let module KR = Keyring.Make(KV)(Enc) in
    let module WmClock = struct
      let now = fun () ->
        let int_of_d_ps (d, ps) =
          d * 86_400 + Int64.(to_int (div ps 1_000_000_000_000L))
        in
        int_of_d_ps @@ Pclock.now_d_ps clock
    end in
    let module D = Dispatch(Data)(Http_srv)(KR)(WmClock) in
    Cohttp_mirage.Server_with_conduit.connect con >>= fun http_srv ->
    tls_init certs >>= fun cfg ->
    let https_port = Key_gen.https_port () in
    let tls = `TLS (cfg, `TCP https_port) in
    let http_port = Key_gen.http_port () in
    let tcp = `TCP http_port in
    (* create the database *)
    KR.create storage_config >>= fun keyring ->
    let https =
      Https_log.info (fun f -> f "listening on %d/TCP" https_port);
      http_srv tls @@ D.serve (D.dispatcher data keyring)
    in
    let http =
      Http_log.info (fun f -> f "listening on %d/TCP" http_port);
      (*http tcp @@ D.serve (D.redirect https_port)*)
      http_srv tcp @@ D.serve (D.dispatcher data keyring)
    in
    Lwt.join [ https; http ]

end
