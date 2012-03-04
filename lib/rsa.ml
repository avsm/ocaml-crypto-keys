open Cryptokit

(* RSA *)
(* FIXME: do not put in weblib ? *)

exception RSA_error

let _ =
  Callback.register_exception "ssl_ext_exn_rsa_error" RSA_error;


type rsa_key

external rsa_read_privkey : string -> rsa_key = "ocaml_ssl_ext_rsa_read_privkey"
external rsa_read_pubkey : string -> rsa_key = "ocaml_ssl_ext_rsa_read_pubkey"

external rsa_get_size : rsa_key -> int = "ocaml_ssl_ext_rsa_get_size"
external rsa_get_n : rsa_key -> string = "ocaml_ssl_ext_rsa_get_n"
external rsa_get_e : rsa_key -> string = "ocaml_ssl_ext_rsa_get_e"
external rsa_get_d : rsa_key -> string = "ocaml_ssl_ext_rsa_get_d"
external rsa_get_p : rsa_key -> string = "ocaml_ssl_ext_rsa_get_p"
external rsa_get_q : rsa_key -> string = "ocaml_ssl_ext_rsa_get_q"
external rsa_get_dp : rsa_key -> string = "ocaml_ssl_ext_rsa_get_dp"
external rsa_get_dq : rsa_key -> string = "ocaml_ssl_ext_rsa_get_dq"
external rsa_get_qinv : rsa_key -> string = "ocaml_ssl_ext_rsa_get_qinv"

(** valeur entière d'un chiffre hexa *)
let char_of_hex_value c =
  int_of_char c - (
    if c >= '0' && c <= '9' then 48 (*int_of_char '0'*)
    else if c >= 'A' && c <= 'F' then 55 (* int_of_char 'A' - 10 *)
    else if c >= 'a' && c <= 'f' then 87 (* int_of_char 'a' - 10 *)
    else assert false
  )

let init n f =
  if n >= 0
  then
    let s = String.create n in
    for i = 0 to pred n do
      String.set s i (f i)
    done ;
    s
  else
    let n = (- n) in
    let s = String.create n in
    for i = pred n downto 0 do
      String.set s i (f (n-i-1))
    done ;
    s

let string_of_hex s = 
  let l = String.length s in
  if l land 1 = 1 then invalid_arg "String.from_hex" ;
  init (l lsr 1) (
    fun i ->
      let i = i lsl 1 in
      Char.chr (
        (char_of_hex_value (String.get s i) lsl 4) +
          (char_of_hex_value (String.get s (i+1)))
      )
  )

let rsa_key_to_cryptokit_hex_rsa rsa_key = {
  RSA.size = rsa_get_size(rsa_key) * 8; (* the result is in bytes whereas Cryptokit.RSA uses bits *)
  RSA.n = string_of_hex (rsa_get_n(rsa_key));
  RSA.e = string_of_hex (rsa_get_e(rsa_key));
  RSA.d = string_of_hex (rsa_get_d(rsa_key));
  RSA.p = string_of_hex (rsa_get_p(rsa_key));
  RSA.q = string_of_hex (rsa_get_q(rsa_key));
  RSA.dp = string_of_hex (rsa_get_dp(rsa_key));
  RSA.dq = string_of_hex (rsa_get_dq(rsa_key));
  RSA.qinv = string_of_hex (rsa_get_qinv(rsa_key));
}

module C = Cryptokit

let rng () = C.Random.device_rng "/dev/random"

let from_hex s = (* if s = "" then "" else *) C.transform_string (C.Hexa.decode()) s
let to_hex s = (* if s = "" then "" else *) C.transform_string (C.Hexa.encode()) s

let from_base64 s = C.transform_string (C.Base64.decode()) s
let to_base64 s = C.transform_string (C.Base64.encode_compact()) s
let to_base64_m s = C.transform_string (C.Base64.encode_multiline()) s

let hash s = C.hash_string (C.Hash.sha256()) s

let symetric direction key s =
  let cipher = C.Cipher.aes ~pad:C.Padding._8000 key direction in
  C.transform_string cipher s

let symetric_encrypt = symetric C.Cipher.Encrypt
let symetric_decrypt = symetric C.Cipher.Decrypt

let new_rsa_empty_key () = {
  C.RSA.size = 0;
  C.RSA.n = "";
  C.RSA.e = "";
  C.RSA.d = "";
  C.RSA.p = "";
  C.RSA.q = "";
  C.RSA.dp = "";
  C.RSA.dq = "";
  C.RSA.qinv = "";
}

let print_rsa_key rsa_key =
  print_endline (Printf.sprintf " \n\
let rsa_key = { \n\
RSA.size = %d; \n\
RSA.n = \"%s\"; \n\
RSA.e = \"%s\"; \n\
RSA.d = \"%s\"; \n\
RSA.p = \"%s\"; \n\
RSA.q = \"%s\"; \n\
RSA.dp = \"%s\"; \n\
RSA.dq = \"%s\"; \n\
RSA.qinv = \"%s\"; \n\
}" rsa_key.C.RSA.size (to_hex rsa_key.C.RSA.n) (to_hex rsa_key.C.RSA.e) (to_hex rsa_key.C.RSA.d)
    (to_hex rsa_key.C.RSA.p) (to_hex rsa_key.C.RSA.q) (to_hex rsa_key.C.RSA.dp) (to_hex rsa_key.C.RSA.dq) (to_hex rsa_key.C.RSA.qinv))

let sign rsa_sig_privkey s =
  C.RSA.sign_CRT rsa_sig_privkey s

let unsign rsa_sig_pubkey s =
  C.RSA.unwrap_signature rsa_sig_pubkey s

let random_key () =
  C.Random.string (C.Random.secure_rng) 32

(* Read an RSA private key from a file.
   If the file is password protected, a password will be asked in the console *)
let read_rsa_privkey file = try
  let rsa = rsa_read_privkey file in
  rsa_key_to_cryptokit_hex_rsa rsa
with RSA_error -> failwith "Read RSA private key failure"

(* Read an RSA public key from a file.
   If the file is password protected, a password will be asked in the console *)
let read_rsa_pubkey file = try
  let rsa = rsa_read_pubkey file in
  rsa_key_to_cryptokit_hex_rsa rsa
with RSA_error -> failwith "Read RSA public key failure"
