open Core_kernel
open Libexecution
open Libcommon
open Types
open Lwt
open Lwt_result.Infix
module Db = Libbackend_basics.Db
module Config = Libbackend_basics.Config

let pp_gcloud_err (err : Gcloud.Auth.error) : string =
  Gcloud.Auth.pp_error Format.str_formatter err ;
  Format.flush_str_formatter ()


type deploy_status =
  | Deploying
  | Deployed
[@@deriving eq, show, yojson]

type static_asset_error =
  [ `GcloudAuthError of string
  | `FailureUploadingStaticAsset of string
  | `FailureDeletingStaticAsset of string ]

type static_deploy =
  { deploy_hash : string
  ; url : string
  ; last_update : Time.t
  ; status : deploy_status }

let static_deploy_to_yojson (sd : static_deploy) : Yojson.Safe.t =
  `Assoc
    [ ("deploy_hash", `String sd.deploy_hash)
    ; ("url", `String sd.url)
    ; ( "last_update"
      , `String
          (* Js.Date.parse expects ISO-8601 formatted string *)
          (Core.Time.to_string_iso8601_basic
             sd.last_update
             ~zone:Core.Time.Zone.utc) )
    ; ("status", deploy_status_to_yojson sd.status) ]


let oauth2_token () : (string, [> static_asset_error]) Lwt_result.t =
  let scopes = ["https://www.googleapis.com/auth/devstorage.read_write"] in
  let r = Gcloud.Auth.get_access_token ~scopes () in
  match%lwt r with
  | Ok token_info ->
      Lwt_result.return token_info.token.access_token
  | Error x ->
      Caml.print_endline ("Gcloud oauth error: " ^ pp_gcloud_err x) ;
      Lwt_result.fail (`GcloudAuthError (pp_gcloud_err x))


(* Copied from Canvas.ml to allow moving this to Libbackend_basics *)
let name_for_id (id : Uuidm.t) : string =
  Db.fetch_one
    ~name:"fetch_canvas_name"
    "SELECT name FROM canvases WHERE id = $1"
    ~params:[Uuid id]
  |> List.hd_exn


let app_hash (canvas_id : Uuidm.t) =
  Nocrypto.Hash.SHA1.digest
    (Cstruct.of_string
       ( name_for_id canvas_id
       (* enough to make this hash not easily discoverable *)
       ^ "SOME SALT HERE"
       ^ Config.static_assets_salt_suffix ))
  |> Cstruct.to_string
  |> B64.encode ~alphabet:B64.uri_safe_alphabet
  |> Util.maybe_chop_suffix ~suffix:"="
  |> String.lowercase
  |> fun s -> String.prefix s 63


let url (canvas_id : Uuidm.t) (deploy_hash : string) variant : string =
  let domain =
    match variant with
    | `Short ->
        ".darksa.com"
    | `Long ->
        ".darkstaticassets.com"
  in
  String.concat
    ~sep:"/"
    ["https:/"; name_for_id canvas_id ^ domain; app_hash canvas_id; deploy_hash]


(* TODO [polish] could instrument this to error on bad deploy hash, maybe also
 * unknown file *)
let url_for (canvas_id : Uuidm.t) (deploy_hash : string) variant (file : string)
    : string =
  url canvas_id deploy_hash variant ^ "/" ^ file


let latest_deploy_hash (canvas_id : Uuidm.t) : string =
  let branch = "main" in
  Db.fetch_one
    ~name:"select latest deploy hash"
    ~subject:(Uuidm.to_string canvas_id)
    "SELECT deploy_hash FROM static_asset_deploys
    WHERE canvas_id=$1 AND branch=$2 AND live_at IS NOT NULL
    ORDER BY created_at desc
    LIMIT 1"
    ~params:[Uuid canvas_id; String branch]
  |> List.hd_exn


let upload_to_bucket
    (filename : string)
    (body : string)
    (canvas_id : Uuidm.t)
    (deploy_hash : string) : (unit, [> static_asset_error]) Lwt_result.t =
  let uri =
    Uri.make
      ()
      ~scheme:"https"
      ~host:"www.googleapis.com"
      ~path:
        ( "upload/storage/v1/b/"
        ^ (Config.static_assets_bucket |> Option.value_exn)
        ^ "/o" )
      ~query:
        [ ("uploadType", ["multipart"])
        ; ("contentEncoding", ["gzip"])
        ; ("name", [app_hash canvas_id ^ "/" ^ deploy_hash ^ "/" ^ filename]) ]
  in
  let ct = Magic_mime.lookup filename in
  let cl = String.length body |> string_of_int in
  (*
   * Correctly send object metadata using a multi-part upload with both the raw asset and the metadata in JSON.
   * Multipart uploads: https://cloud.google.com/storage/docs/json_api/v1/how-tos/multipart-upload
   * Metadata schema:   https://cloud.google.com/storage/docs/json_api/v1/objects#resource
   * *)
  let body_string = body |> Ezgzip.compress in
  let boundary = "metadata_boundary" in
  let body =
    Printf.sprintf
      {|--%s
Content-type: application/json; charset=UTF-8

{
  "cacheControl": "public, max-age=604800, immutable",
  "contentType": "%s",
  "size": %s
}

--%s
Content-type: %s

%s
--%s--|}
      boundary
      ct
      cl
      boundary
      ct
      body_string
      boundary
  in
  let headers =
    oauth2_token ()
    >|= fun token ->
    Cohttp.Header.of_list
      [ ("Authorization", "Bearer " ^ token)
      ; ("Content-type", "multipart/related; boundary=" ^ boundary)
      ; ("Content-length", body |> String.length |> string_of_int) ]
  in
  headers
  >|= (fun headers ->
        Cohttp_lwt_unix.Client.post
          uri
          ~headers
          ~body:(body |> Cohttp_lwt.Body.of_string))
  >>= fun x ->
  Lwt.bind x (fun (resp, _) ->
      match resp.status with
      | `OK | `Created ->
          Lwt_result.return ()
      | _ as s ->
          Lwt_result.fail
            (`FailureUploadingStaticAsset
              ( "Failure uploading static asset: "
              ^ Cohttp.Code.string_of_status s )))


let start_static_asset_deploy
    ~(user : Account.user_info) (canvas_id : Uuidm.t) (branch : string) :
    static_deploy =
  let deploy_hash =
    Nocrypto.Hash.SHA1.digest
      (Cstruct.of_string
         (Uuidm.to_string canvas_id ^ Time.to_string (Time.now ())))
    |> Cstruct.to_string
    |> B64.encode ~alphabet:B64.uri_safe_alphabet
    |> Util.maybe_chop_suffix ~suffix:"="
    |> String.lowercase
    |> fun s -> String.prefix s 10
  in
  let last_update =
    Db.fetch_one
      ~name:"add static_asset_deploy record"
      ~subject:deploy_hash
      "INSERT INTO static_asset_deploys
        (canvas_id, branch, deploy_hash, uploaded_by_account_id)
        VALUES ($1, $2, $3, $4) RETURNING created_at"
      ~params:[Uuid canvas_id; String branch; String deploy_hash; Uuid user.id]
    |> List.hd_exn
    |> Db.date_of_sqlstring
  in
  { deploy_hash
  ; url = url canvas_id deploy_hash `Short
  ; last_update
  ; status = Deploying }


(* This is for Ellen's demo, and is just the backend of a libdarkinternal function. *)
let delete_assets_for_ellens_demo (canvas_id : Uuidm.t) : unit =
  Db.delete
    ~name:"delete_ellens_assets"
    ~subject:(Uuidm.to_string canvas_id)
    "DELETE FROM static_asset_deploys where canvas_id = $1"
    ~params:[Uuid canvas_id]
  |> ignore


(* since postgres doesn't have named transactions, we just delete the db
 * record in question. For now, we're leaving files where they are; the right
 * thing to do here would be to shell out to `gsutil -m rm -r`, but shelling out
 * from ocaml causes ECHILD errors, so leaving this for a later round of
 * 'garbage collection' work, in which we can query for files/dirs not known to
 * the db and delete them *)
let delete_static_asset_deploy
    ~(user : Account.user_info)
    (canvas_id : Uuidm.t)
    (branch : string)
    (deploy_hash : string) : unit =
  Db.run
    ~name:"delete static_asset_deploy record"
    ~subject:deploy_hash
    "DELETE FROM static_asset_deploys
    WHERE canvas_id=$1 AND branch=$2 AND deploy_hash=$3 AND uploaded_by_account_id=$4"
    ~params:[Uuid canvas_id; String branch; String deploy_hash; Uuid user.id]


let finish_static_asset_deploy (canvas_id : Uuidm.t) (deploy_hash : string) :
    static_deploy =
  let last_update =
    Db.fetch_one
      ~name:"finish static_asset_deploy record"
      ~subject:deploy_hash
      "UPDATE static_asset_deploys
      SET live_at = NOW()
      WHERE canvas_id = $1 AND deploy_hash = $2 RETURNING live_at"
      ~params:[Uuid canvas_id; String deploy_hash]
    |> List.hd_exn
    |> Db.date_of_sqlstring
  in
  { deploy_hash
  ; url = url canvas_id deploy_hash `Short
  ; last_update
  ; status = Deployed }


let all_deploys_in_canvas (canvas_id : Uuidm.t) : static_deploy list =
  Db.fetch
    ~name:"all static_asset_deploys by canvas"
    "SELECT deploy_hash, created_at, live_at FROM static_asset_deploys
    WHERE canvas_id=$1 ORDER BY created_at DESC LIMIT 25"
    ~params:[Uuid canvas_id]
  |> List.map ~f:(function
         | [deploy_hash; created_at; live_at] ->
             let isLive = live_at <> "" in
             let last_update =
               Db.date_of_sqlstring (if isLive then live_at else created_at)
             in
             let status = if isLive then Deployed else Deploying in
             let url = url canvas_id deploy_hash `Short in
             {deploy_hash; url; last_update; status}
         | _ ->
             Exception.internal "Bad DB format for static assets deploys")
