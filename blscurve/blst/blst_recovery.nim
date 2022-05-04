import
  sequtils,
  stew/[results, objects],
  ./blst_lowlevel,
  ./blst_min_pubkey_sig_core

export
  results

type
  ID* = object
    ## A point on X axis used for key and signature recovery
    point: blst_scalar

func fromUint32*(T: type ID, value: array[8, uint32]): T =
  result.point.blst_scalar_from_uint32(value)

func `/`(a: blst_fr, b: blst_fr): blst_fr =
  var t: blst_fr
  blst_fr_eucl_inverse(t, b)
  result.blst_fr_mul(a, t)

func toScalar(a: blst_fr): blst_scalar =
  result.blst_scalar_from_fr(a)

func `*=`(a: var blst_fr, b: blst_fr) =
  a.blst_fr_mul(a, b)

func `*`(a: blst_fr, b: blst_fr): blst_fr=
  result.blst_fr_mul(a, b)

func `-`(a: blst_fr, b: blst_fr): blst_fr=
  result.blst_fr_sub(a, b)

func `+=`(a: var blst_fr, b: blst_fr) =
  a.blst_fr_add(a, b)

func `+`(a: blst_fr, b: blst_fr): blst_fr =
  result.blst_fr_add(a, b)

func `*=`(a: var blst_p2; s: blst_fr) =
  a.blst_p2_mult(a, s.toScalar(), 255)

func `*`(a: blst_p2; s: blst_fr): blst_p2=
  result.blst_p2_mult(a, s.toScalar(), 255)

func `+=`(a: var blst_p2; b: blst_p2) =
  a.blst_p2_add(a, b)

func toFr(sk: SecretKey): blst_fr =
  result.blst_fr_from_scalar(sk.getScalar)

func toFr(id: ID): blst_fr =
  result.blst_fr_from_scalar(id.point)

func toP2(s: Signature): blst_p2 =
  result.blst_p2_from_affine(s.getPoint)

func add*(a: SecretKey, b: SecretKey): SecretKey =
  var r: blst_fr
  blst_fr_add(r, a.toFr, b.toFr)
  SecretKey.fromFr(r)

func evaluatePolynomial(cfs: openArray[blst_fr], x: blst_fr): blst_fr =
  let count = len(cfs)
  if count == 0:
    return blst_fr()

  if count == 1:
    return cfs[0]

  # Horner's method
  # We will calculate a0 + X(a1 + X(a2 + ..X(an-1  + Xan))
  var y = cfs[count - 1]
  for i in 2 .. count:
    y = y * x + cfs[count - i]

  return y

func lagrangeInterpolation[T, U](yVec: openArray[T], xVec: openArray[U]): Result[T, cstring] =
  let k = len(xVec)
  if k == 0 or k != len(yVec):
    return err "invalid inputs"

  if k == 1:
    return ok yVec[0]

  # We calculate L(0) so we can simplify
  # (X - X0) .. (X - Xj-1) * (X - Xj+1) .. (X - Xk) to just X0 * X1 .. Xk
  # Later we can divide by Xi for each basis polynomial li(0)
  var a = xVec[0]
  for i in 1 ..< k:
    a *= xVec[i]

  if a.isZeroMemory:
    return err "zero secret share id"

  var r: T
  for i in 0 ..< k:
    var b = xVec[i]
    for j in 0 ..< k:
      if j != i:
        let v = xVec[j] - xVec[i]
        if v.isZeroMemory:
          return err "duplicate secret share id"
        b *= v
    # Ith basis polynomial for X = 0
    let li0 = (a / b)
    r += yVec[i] * li0

  ok(r)

func genSecretShare*(mask: openArray[SecretKey], id: ID): SecretKey =
  ## https://en.wikipedia.org/wiki/Shamir%27s_Secret_Sharing
  ##
  ## In Shamir's secret sharing, a secret is encoded as a n-degree polynomial
  ## F where the secret value is equal to F(0). Here, F(0) is provided as mask[0].
  ##
  ## A key share is generated by evaluating the polynomial in the `id` point.
  ## Later we can use at least N of these points to recover the original secret.
  ##
  ## Furthermore, if we sign some message M with at least K of the secret key
  ## shares we can restore from them the signature of the same message signed
  ## with original secret key.
  ##
  ## For a more gentle introductiont to Shamir's secret sharing, see also:
  ##
  ## https://github.com/dashpay/dips/blob/master/dip-0006/bls_m-of-n_threshold_scheme_and_dkg.md
  ## https://medium.com/toruslabs/what-distributed-key-generation-is-866adc79620
  let cfs = mask.mapIt(it.toFr)
  SecretKey.fromFr evaluatePolynomial(cfs, id.toFr)

func recover*(secrets: openArray[SecretKey],
              ids: openArray[ID]): Result[SecretKey, cstring] =
  ## Recover original secret key from N points generated by genSecretShare
  let ys = secrets.mapIt(it.toFr)
  let xs = ids.mapIt(it.toFr)
  ok SecretKey.fromFr(? lagrangeInterpolation(ys, xs))

func recover*(signs: openArray[Signature],
              ids: openArray[ID]): Result[Signature, cstring] =
  ## Recover signature from the original secret key from N signatures
  ## produced by at least N different secret shares generated by genSecretShare
  let ys = signs.mapIt(it.toP2)
  let xs = ids.mapIt(it.toFr)
  ok Signature.fromP2(? lagrangeInterpolation(ys, xs))