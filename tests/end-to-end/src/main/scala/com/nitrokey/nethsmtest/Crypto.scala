package com.nitrokey.nethsmtest

import java.math.BigInteger
import java.security.MessageDigest
import java.security.Signature
import java.security.Security
import java.security.interfaces.RSAPrivateKey
import java.security.interfaces.RSAPublicKey
import java.security.interfaces.RSAPrivateCrtKey
import java.security.KeyFactory
import java.security.spec.RSAPrivateKeySpec
import java.security.spec.RSAPublicKeySpec
import java.security.KeyPairGenerator
import java.security.KeyPair
import java.security.SecureRandom
import com.typesafe.scalalogging.LazyLogging
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.crypto.signers.PSSSigner
import org.bouncycastle.crypto.engines.RSABlindingEngine
import org.bouncycastle.crypto.digests._
import org.bouncycastle.crypto.params.RSABlindingParameters
import org.bouncycastle.crypto.params.RSAKeyParameters
import org.bouncycastle.crypto.engines.RSAEngine
import scala.concurrent.Future
import scala.concurrent.ExecutionContext.Implicits.global
import java.security.spec.RSAPrivateCrtKeySpec
import NetHsmProtocol._
import javax.crypto.Cipher

/**
 * Cryptography-related functions. If a cipher suite is required as a parameter, its the issuer's cipher suite (e.g. "SHA256-RSA2048-CHAUM83")
 */
object Crypto extends LazyLogging {

  /**
   * cipherParam: See https://bouncycastle.org/specifications.html
   */
  def encrypt(message: Seq[Byte], cipherParam: String, key: NkPublicRsaKey) = {
    Security.addProvider(new org.bouncycastle.jce.provider.BouncyCastleProvider())
    val cipher: Cipher = Cipher.getInstance(cipherParam, BouncyCastleProvider.PROVIDER_NAME)
    cipher.init(Cipher.ENCRYPT_MODE, key.javaPublicKey)
    cipher.doFinal(message.toArray)
  }

  /** 
   * Create a hash from a String. Found in net.liftweb.util.SecurityHelpers 
   */
  def hash(message: String, hashAlgorithm: String): Seq[Byte] = {
    Security.addProvider(new org.bouncycastle.jce.provider.BouncyCastleProvider())
    val md = MessageDigest.getInstance(hashAlgorithm, BouncyCastleProvider.PROVIDER_NAME)
    md.update(message.getBytes("UTF-8"))
    md.digest
  }

  def sign(message: String, signatureAlgorithm: String, privateKey: NkPrivateRsaCrtKey): Seq[Byte] = {
    sign(message.getBytes("UTF-8"), signatureAlgorithm, privateKey)
  }

  /**
   * signatureAlgorithm: Example "SHA1withRSA"
   **/
  def sign(array: Seq[Byte], signatureAlgorithm: String, privateKey: NkPrivateRsaCrtKey): Seq[Byte] = {
    Security.addProvider(new org.bouncycastle.jce.provider.BouncyCastleProvider())
    val sig: Signature = Signature.getInstance(signatureAlgorithm, BouncyCastleProvider.PROVIDER_NAME)
    sig.initSign(privateKey.javaPrivateKey)
    sig.update(array.toArray)
    sig.sign
  }  

  def verifySignature(message: String, signature: Seq[Byte], publicKey: NkPublicRsaKey, signatureAlgorithm: String): Boolean = {
      verifySignatureWA(message.getBytes("UTF-8").asInstanceOf[Seq[Byte]], signature, publicKey, signatureAlgorithm)
  }

  /**
   * Create hash and verify it against the given signature.
   * The cipherSuite is not just the hash but the entire combination of hash-signature-blinding (e.g. "SHA256-RSA2048-CHAUM83")
   */
  def verifySignatureWA(array: Seq[Byte], signature: Seq[Byte], publicKey: NkPublicRsaKey, signatureAlgorithm: String): Boolean = {
    try {
      Security.addProvider(new org.bouncycastle.jce.provider.BouncyCastleProvider())
      val sig: Signature = Signature.getInstance(signatureAlgorithm, BouncyCastleProvider.PROVIDER_NAME)
      //val sig: Signature = Signature.getInstance(cipherSuite)
      sig.initVerify(publicKey.javaPublicKey)
      sig.update(array.toArray)
      val res = sig.verify(signature.toArray)
      //logger.debug("verifySignature: result: " + res)
      res
    } catch {
      case e: Exception => {
        logger.debug("verifySignature: Exception: %s" format e)
        false
      }
    }
  }

  def generateRSACrtKeyPair(keyLength: Int): NkPrivateRsaCrtKey = {
    val random: SecureRandom = SecureRandom.getInstance("SHA1PRNG", "SUN")
    val keyGen: KeyPairGenerator = KeyPairGenerator.getInstance("RSA")
    keyGen.initialize(keyLength, random)
    val keyPair: KeyPair = keyGen.genKeyPair()
    val priv = keyPair.getPrivate.asInstanceOf[RSAPrivateCrtKey]
    logger.debug("RSA key pair has been generated successfully.")
    NkPrivateRsaCrtKey(priv) 
  }
  
  /**
   * This function can be applied when converting BigIntegers to Seq[Byte] or Array[Byte].
   * Note that Java's key format uses BigInteger too.
   * See https://stackoverflow.com/questions/24158629/biginteger-tobytearray-returns-purposeful-leading-zeros
   */
  def dropLeadingZero(array: Seq[Byte]): Seq[Byte] =  {
    if (array(0) == 0) array.drop(1)
    else array
  }

}
