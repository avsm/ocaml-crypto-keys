open Rsa
open Lwt
module C = Cryptokit

exception Key_error of string
type key_type = 
  | PEM_PUB
  | PEM_PRIV
  | PEM_CERT
  | DNS_PUB
  | DNS_PRIV
  | SSH_PUB
let string_of_key_type = function
  | PEM_PUB -> "PEM_PUB" 
  | PEM_PRIV-> "PEM_PRIV"
  | PEM_CERT-> "PEM_CERT"
  | DNS_PUB -> "DNS_PUB"
  | DNS_PRIV-> "DNS_PRIV"
  | SSH_PUB -> "SSH_PUB"
let key_type_of_string = function
  |  "PEM_PUB" ->PEM_PUB 
  |  "PEM_PRIV"->PEM_PRIV
  |  "PEM_CERT"->PEM_CERT
  |  "DNS_PUB" ->DNS_PUB 
  |  "DNS_PRIV"->DNS_PRIV
  | "SSH_PUB" -> SSH_PUB
  | a -> raise(Key_error(Printf.sprintf "error key type %s" a))


exception Action_error of string
type action_type = 
  | SIGN
  | TRANSFORM
  | VERIFY
let string_of_action_type = function
  | SIGN     -> "SIGN" 
  | TRANSFORM-> "TRANSFORM"
  | VERIFY   -> "VERIFY"
let action_type_of_strng = function
  | "SIGN"     ->  SIGN      
  | "TRANSFORM"->  TRANSFORM
  | "VERIFY"   ->  VERIFY   
  | a -> raise (Action_error (Printf.sprintf "error action: %s" a))

type key_conf = {
  mutable in_key: string;
  (*     mutable in_ca_cert: string; *)
  mutable in_issuer: string;
  mutable in_ca_priv: string;
  mutable in_type: key_type;
  mutable action : action_type;
  mutable cert_subj : string;
  mutable out_key : string;
  mutable out_type : key_type;
  (* for cert only. how long the certificate will last. *)
  mutable duration : int;
  mutable ns_ip : string;
  mutable ns_port : int;
}

let process_dnskey_rr = 
  let open Dns.Packet in
  function
  | DNSKEY(_, _, bits) -> (
      bitmatch (Bitstring.bitstring_of_string bits) with 
        | {0:8;len:16; exp:len*8:string; modu:-1:string} ->
            Some({C.RSA.size = 0; C.RSA.n = modu;
                  C.RSA.e = exp; C.RSA.d = "";
                  C.RSA.p = ""; C.RSA.q = "";
                  C.RSA.dp = ""; C.RSA.dq = "";
                  C.RSA.qinv = "";})
        | {len:8;exp:len*8:string; modu:-1:string} ->
            Some({C.RSA.size = 0; C.RSA.n = modu;
                  C.RSA.e = exp; C.RSA.d = "";
                  C.RSA.p = ""; C.RSA.q = "";
                  C.RSA.dp = ""; C.RSA.dq = "";
                  C.RSA.qinv = "";})
        | { _ } -> Printf.printf "Invalid RSA DNSKEY format\n%!"; None
    )
  | _ -> None

let dns_pub_of_rsa key =
  let len = String.length key.C.RSA.e in 
  let key_rdata = 
    if (len <= 255) then 
      BITSTRING{len:8; (key.C.RSA.e):len*8:string; 
                        key.C.RSA.n:(String.length key.C.RSA.n)*8:string}
    else 
      BITSTRING{0:8; len:16; (key.C.RSA.e):len*8:string; 
                              key.C.RSA.n:(String.length key.C.RSA.n)*8:string}
  in
    Printf.sprintf "DNSKEY 256 3 5 %s" (C.transform_string (C.Base64.encode_compact ()) 
                                          (Bitstring.string_of_bitstring key_rdata))


let get_dnssec_key ?server:(server="128.232.1.1") ?dns_port:(dns_port = 53) domain =
  try_lwt begin
    let open Dns.Packet in
    lwt reply = Dns_resolver.resolve server dns_port Q_IN Q_DNSKEY
        (Dns.Name.string_to_domain_name domain) 
    in
    match reply.answers with
    |[] ->
      Printf.printf "Failed to get \n%!";
      return None
    |ans::_ ->
      let r = process_dnskey_rr ans.rdata in
      return r
  end
  with e ->
    Printf.printf "failed to resolve name : %s\n%!" (Printexc.to_string e);
    return (None)

let decode_value value = 
  C.transform_string (C.Base64.decode ()) 
    (Re_str.global_replace (Re_str.regexp "=") "" value)

let parse_dnssec_key file =
  let n = ref "" in
  let e = ref "" in
  let d = ref "" in 
  let p = ref "" in
  let q = ref "" in 
  let dp = ref "" in 
  let dq = ref "" in 
  let qinv = ref "" in 
  let fd = open_in file in 
  let rec parse_file in_stream =
    try
      let line = Re_str.split (Re_str.regexp ": ") (input_line in_stream) in 
        match line with
          (* TODO: Need to check if this is an RSA key *)
          | "Modulus" :: value ->
              n := decode_value (List.hd value); parse_file in_stream 
          | "PublicExponent" :: value ->
              e := decode_value (List.hd value); parse_file in_stream             
          | "PrivateExponent" :: value ->
              d := decode_value (List.hd value); parse_file in_stream             
          | "Prime1" :: value ->
              p := decode_value (List.hd value); parse_file in_stream             
          | "Prime2" :: value ->
              q := decode_value (List.hd value); parse_file in_stream             
          | "Exponent1" :: value ->
              dp := decode_value (List.hd value); parse_file in_stream             
          | "Exponent2" :: value ->
              dq:= decode_value (List.hd value); parse_file in_stream             
          | "Coefficient" :: value ->
              qinv := decode_value (List.hd value); parse_file in_stream             
          | typ :: value ->
              Printf.printf "read field:%s\n%!" typ; parse_file in_stream
          | [] -> parse_file in_stream
    with  End_of_file -> ()
  in
    parse_file fd;
    C.RSA.({C.RSA.size = 0; C.RSA.n = !n; C.RSA.e = !e; C.RSA.d = !d;
            C.RSA.p = !p; C.RSA.q = !q; C.RSA.dp = !dp; C.RSA.dq = !dq;
            C.RSA.qinv = !qinv;})

let load_ssh_pub_key file =
  let n_val = ref "" in 
  let e_val = ref "" in 
  let input = open_in file in 
  let buf = input_line input in
    close_in input;
    let key = (Cryptokit.(transform_string (Base64.decode ()) 
                            (List.nth (Re_str.split (Re_str.regexp " ") buf) 1))) in 
(*       Printf.printf "readine key %s \n%!" (Rsa.hex_of_string key); *)
      let _ = 
        bitmatch (Bitstring.bitstring_of_string key) with 
          | { "\x00\x00\x00\x07\x73\x73\x68\x2D\x72\x73\x61":88:string;
        ebytes:32; e:((Int32.to_int ebytes)*8):string;
                      nbytes:32; n:((Int32.to_int nbytes)*8):string; 
                                    _:-1:bitstring} -> 
              n_val := n; e_val := e;
(*               Printf.printf "Matched the string"; *)
          | { _ } -> Printf.printf "Cannot decode key \n%!";
      in
        C.RSA.({C.RSA.size = 0; C.RSA.n =(!n_val); C.RSA.e =(!e_val); C.RSA.d ="";
                C.RSA.p =""; C.RSA.q =""; C.RSA.dp =""; C.RSA.dq ="";
                C.RSA.qinv ="";})

let bitstring_ssh_pub_of_rsa key = 
  let e = 
    if (( (int_of_char (key.C.RSA.e.[0]))  land 0x80) != 0) then 
      ("\x00"  ^ key.C.RSA.e)
    else
      key.C.RSA.e   
  in
    let n =
      if (( (int_of_char (key.C.RSA.n.[0])) land 0x80) != 0) then
        ("\x00" ^ key.C.RSA.n)
      else
        key.C.RSA.n 
    in
    BITSTRING {
      "\x00\x00\x00\x07\x73\x73\x68\x2D\x72\x73\x61":88:string;
      (Int32.of_int (String.length e)):32; e:((String.length e)*8):string;
      (Int32.of_int (String.length n)):32; n:((String.length n)*8):string }
    
let ssh_pub_key_of_rsa key =
 let key_bin =  bitstring_ssh_pub_of_rsa key in
    let key_ssh = (C.transform_string (C.Base64.encode_compact()) 
      (Bitstring.string_of_bitstring key_bin)) in 
      let ext_len = 
        if ( ((String.length key_ssh) mod 3) == 0) then 
          ""
        else 
          String.make (3 - ((String.length key_ssh) mod 3)) '='
      in 
        ("ssh-rsa " ^ key_ssh ^ ext_len ^ "\n")

let ssh_fingerprint_of_rsa key = 
 let key_bin =  bitstring_ssh_pub_of_rsa key in
 let hash = C.hash_string (Cryptokit.Hash.md5 ()) 
            (Bitstring.string_of_bitstring key_bin) in
 let fingerprint = ref "" in 
   String.iter (fun ch -> 
               fingerprint := (Printf.sprintf "%s:%0x" (!fingerprint) 
                                 (int_of_char ch))) 
     hash;
  (!fingerprint)

let load_key server port file typ = 
(*   Printf.printf "loading key %s (%s)\n%!" file (string_of_key_type typ); *)
  match typ with 
    | PEM_PRIV -> 
        return(Some(Rsa.read_rsa_privkey file))
    | PEM_PUB -> 
        return(Some(Rsa.read_rsa_pubkey file))
    | DNS_PUB -> (get_dnssec_key ~server:server ~dns_port:port file)
    | PEM_CERT -> return(None)
    | DNS_PRIV -> return(Some(parse_dnssec_key file))
    | SSH_PUB -> return (Some(load_ssh_pub_key file))
    | _ -> 
(*         Printf.eprintf "Invalid key type to read\n%!";  *)
        return(None)

let convert_key conf =
(*   Printf.printf "converting key types...\n"; *)
  lwt key = load_key conf.ns_ip conf.ns_port conf.in_key conf.in_type in
  match key with 
    | Some(key) ->
      begin
        match conf.out_type with
          | PEM_PRIV -> return(Rsa.write_rsa_privkey conf.out_key key)
          | PEM_PUB -> return(Rsa.write_rsa_pubkey conf.out_key key)
          | DNS_PRIV -> 
            return(Printf.eprintf "lib doesn't support DNS_PRIV key generation\n")
          | DNS_PUB -> 
              let str = dns_pub_of_rsa key in 
            let out_file = open_out conf.out_key in 
              output_string out_file (str ^ "\n");
              return (close_out out_file)                
          | PEM_CERT ->  return(Printf.eprintf "lib doesn't support PEM_CERT\n")
          | SSH_PUB -> 
            let str = ssh_pub_key_of_rsa key in 
            let out_file = open_out conf.out_key in 
              output_string out_file (str ^ "\n");
              return (close_out out_file) 
          | _ -> return (Printf.eprintf "Invalid key type to read\n%!")
      end
    | None -> failwith "Failed to read input key" 

let sign_key conf =
  Printf.printf "signing key...\n";
  lwt key = load_key  conf.ns_ip conf.ns_port conf.in_key conf.in_type in
  lwt sign_key = load_key  conf.ns_ip conf.ns_port conf.in_ca_priv PEM_PRIV in 
  (*     print_rsa_key sign_key; *)
  match (key, sign_key) with 
    | (Some(key), Some(sign_key)) ->
        begin
          match conf.out_type with
            | PEM_PRIV -> return(Rsa.write_rsa_privkey conf.out_key key)
            | PEM_PUB ->  return(Rsa.write_rsa_pubkey conf.out_key key)
            | DNS_PRIV ->  return(Printf.eprintf 
                                    "lib doesn't support DNS_PRIV key generation\n")
            | DNS_PUB -> return(Printf.eprintf 
                                  "lib doesn't support DNS_PUB key generation\n")
            | PEM_CERT -> 
               return(Rsa.sign_rsa_pub_key key sign_key conf.in_issuer 
                      conf.cert_subj conf.duration conf.out_key)
        end
    | (_, _) -> failwith "Failed to read input key"

let string_of_sign_key conf =
  Printf.printf "signing key...\n";
  lwt key = load_key  conf.ns_ip conf.ns_port conf.in_key conf.in_type in
  lwt sign_key = load_key  conf.ns_ip conf.ns_port conf.in_ca_priv PEM_PRIV in 
  (*     print_rsa_key sign_key; *)
  match (key, sign_key) with 
    | (Some(key), Some(sign_key)) ->
        begin
          match conf.out_type with
(*            | PEM_PRIV -> return(Rsa.write_rsa_privkey conf.out_key key)
            | PEM_PUB ->  return(Rsa.write_rsa_pubkey conf.out_key key)
            | DNS_PRIV ->  return(Printf.eprintf 
                                    "lib doesn't support DNS_PRIV key generation\n")
            | DNS_PUB -> return(Printf.eprintf 
                                  "lib doesn't support DNS_PUB key
                                  generation\n")*)
            | PEM_CERT -> 
               return(Rsa.string_of_sign_rsa_pub_key key sign_key conf.in_issuer 
                      conf.cert_subj conf.duration conf.out_key)
            | _ -> 
              failwith "Failed to sign key"
        end
    | (_, _) -> failwith "Failed to read input key"

let process conf = 
  match conf.action with 
    | TRANSFORM -> convert_key conf
    | SIGN -> sign_key conf
    | _ -> return (Printf.printf "Unsupported action %s" (string_of_action_type
                                                            conf.action))
let string_of_process conf = 
  match conf.action with 
    | TRANSFORM -> failwith "Unsupported action"
    | SIGN -> string_of_sign_key conf
    | _ -> failwith (Printf.sprintf "Unsupported action %s" 
                        (string_of_action_type conf.action))

let dnskey_of_pem_pub_file file =
  lwt tmp = load_key "" 0 file PEM_PUB in
  match tmp with
    | Some(key) -> 
        let ret = dns_pub_of_rsa key in 
          return (Some([ret]))
    | None -> return (None)

let dnskey_of_pem_priv_file file =
  lwt tmp = load_key "" 0 file PEM_PRIV in
  match tmp with
  | Some(key) -> 
    let ret = dns_pub_of_rsa key in 
    return (Some([ret]))
  | None -> return (None)

let ssh_pub_key_of_domain  ?server:(server="128.232.1.1") 
?port:(port = 53) domain = 
  lwt tmp = get_dnssec_key ~server:server ~dns_port:port domain in 
  match (tmp) with
  | Some(key) -> 
    let ret = ssh_pub_key_of_rsa key in 
    return(Some([ret]))
  | None -> return(None)

let ssh_fingerprint_of_domain  ?server:(server="128.232.1.1") 
      ?port:(port=53) domain =                                        
  lwt tmp = get_dnssec_key ~server:server ~dns_port:port domain in
  match tmp with
    | Some(key) -> 
        let ret = ssh_fingerprint_of_rsa key in 
          return(Some([ret]))
    | None -> return(None)

let create_rsa_key file len = 
  Rsa.create_rsa_key file len
