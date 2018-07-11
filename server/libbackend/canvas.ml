open Core_kernel
open Libexecution

open Util
open Types

module RTT = Types.RuntimeT
module RT = Runtime
module TL = Toplevel

type toplevellist = TL.toplevel list [@@deriving eq, show, yojson]
type canvas = { host : string
              ; owner : Uuidm.t
              ; id : Uuidm.t
              ; ops : Op.oplist
              ; handlers : toplevellist
              ; dbs: toplevellist
              ; user_functions: RTT.user_fn list
              } [@@deriving eq, show]

(* ------------------------- *)
(* Toplevel *)
(* ------------------------- *)
let upsert_tl (tlid: tlid) (pos: pos) (data: TL.tldata) (tls : toplevellist)
  : toplevellist =
  let tl : TL.toplevel =
    { tlid = tlid
    ; pos = pos
    ; data = data}
  in
  tls
  |> List.filter ~f:(fun x -> x.tlid <> tl.tlid)
  |> (@) [tl]

let upsert_db tlid pos data c =
  { c with dbs = upsert_tl tlid pos data c.dbs}

let upsert_handler tlid pos data c =
  { c with handlers = upsert_tl tlid pos data c.handlers}

let upsert_function (user_fn: RuntimeT.user_fn) (c: canvas) : canvas =
  let fns = List.filter ~f:(fun x -> x.tlid <> user_fn.tlid) c.user_functions in
  { c with user_functions = fns @ [user_fn] }

let remove_toplevel (tlid: tlid) (c: canvas) : canvas =
  let handlers = List.filter ~f:(fun x -> x.tlid <> tlid) c.handlers in
  let dbs = List.filter ~f:(fun x -> x.tlid <> tlid) c.dbs in
  { c with handlers = handlers
         ; dbs = dbs }

let apply_to_toplevel ~(f:(TL.toplevel -> TL.toplevel)) (tlid: tlid) (tls: toplevellist) =
  match List.find ~f:(fun t -> t.tlid = tlid) tls with
  | Some tl ->
    let newtl = f tl in
    upsert_tl newtl.tlid newtl.pos newtl.data tls
  | None ->
    tls

let apply_to_all_toplevels ~(f:(TL.toplevel -> TL.toplevel)) (tlid:tlid) (c: canvas) : canvas =
  { c with handlers = apply_to_toplevel ~f tlid c.handlers
         ; dbs = apply_to_toplevel ~f tlid c.dbs }

let apply_to_db ~(f:(RTT.DbT.db -> RTT.DbT.db)) (tlid: tlid) (c:canvas) : canvas =
  let tlf (tl: TL.toplevel) =
    let data =
      match tl.data with
      | TL.DB db -> TL.DB (f db)
      | _ -> Exception.client "Provided ID is not for a DB"
    in
    { tl with data = data }
  in { c with dbs = apply_to_toplevel tlid ~f:tlf c.dbs }


let apply_to_handler  ~f tlid c =
  { c with handlers = apply_to_toplevel ~f tlid c.handlers}

let move_toplevel (tlid: tlid) (pos: pos) (c: canvas) : canvas =
  apply_to_all_toplevels ~f:(fun tl -> { tl with pos = pos }) tlid c

(* ------------------------- *)
(* Build *)
(* ------------------------- *)

let apply_op (op : Op.op) (c : canvas ref) : unit =
  c :=
    !c |>
    match op with
    | SetHandler (tlid, pos, handler) ->
      upsert_handler tlid pos (TL.Handler handler)
    | CreateDB (tlid, pos, name) ->
      if name = ""
      then Exception.client ("DB must have a name")
      else
        let db = User_db.create !c.host name tlid in
        upsert_db tlid pos (TL.DB db)
    | AddDBCol (tlid, colid, typeid) ->
      apply_to_db ~f:(User_db.add_col colid typeid) tlid
    | SetDBColName (tlid, id, name) ->
      apply_to_db ~f:(User_db.set_col_name id name) tlid
    | ChangeDBColName (tlid, id, name) ->
      apply_to_db ~f:(User_db.change_col_name id name) tlid
    | SetDBColType (tlid, id, tipe) ->
      apply_to_db ~f:(User_db.set_col_type id (Dval.tipe_of_string tipe)) tlid
    | ChangeDBColType (tlid, id, tipe) ->
      apply_to_db ~f:(User_db.change_col_type id (Dval.tipe_of_string tipe)) tlid
    | InitDBMigration (tlid, id, rbid, rfid, kind) ->
      apply_to_db ~f:(User_db.initialize_migration id rbid rfid kind) tlid
    | SetExpr (tlid, id, e) ->
      apply_to_all_toplevels ~f:(TL.set_expr id e) tlid
    | DeleteTL tlid -> remove_toplevel tlid
    | MoveTL (tlid, pos) -> move_toplevel tlid pos
    | TLSavepoint _ -> ident
    | DeprecatedSavepoint -> ident
    | DeprecatedSavepoint2 _ -> ident
    | SetFunction user_fn ->
      upsert_function user_fn
    | DeprecatedDeleteAll
    | DeprecatedUndo | DeprecatedRedo
    | UndoTL _ | RedoTL _ ->
      Exception.internal ("This should have been preprocessed out! " ^ (Op.show_op op))

(* https://stackoverflow.com/questions/15939902/is-select-or-insert-in-a-function-prone-to-race-conditions/15950324#15950324 *)
let fetch_canvas_id (owner:Uuidm.t) (host:string) : Uuidm.t =
  let sql =
    Printf.sprintf
      "SELECT canvas_id(%s, %s, %s)"
      (Db.escape (Uuid (Util.create_uuid ())))
      (Db.escape (Uuid owner))
      (Db.escape (String host))
  in
  Db.fetch_one
    ~name:"fetch_canvas_id"
    sql
    ~params:[]
  |> List.hd_exn
  |> Uuidm.of_string
  |> Option.value_exn

let add_ops (c: canvas ref) (oldops: Op.op list) (newops: Op.op list) : unit =
  let reduced_ops = Undo.preprocess (oldops @ newops) in
  List.iter ~f:(fun op -> apply_op op c) reduced_ops;
  c := { !c with ops = oldops @ newops }

let minimize (c : canvas) : canvas =
  let ops =
    c.ops
    |> Undo.preprocess
    |> List.filter ~f:Op.has_effect
  in { c with ops = ops }


(* ------------------------- *)
(* Serialization *)
(* ------------------------- *)
let owner (host:string) : Uuidm.t =
  host
  |> Account.auth_domain_for
  |> Account.owner
  |> fun o ->
       match o with
       | Some owner -> owner
       | None -> Exception.client ("No Canvas found for host " ^ host)


let create ?(load=true) (host: string) (newops: Op.op list) : canvas ref =
  let oldops =
    if load
    then Serialize.search_and_load host
    else []
  in

  let owner = owner host in

  let id = fetch_canvas_id owner host in
  let c =
    ref { host = host
        ; owner = owner
        ; id = id
        ; ops = []
        ; handlers = []
        ; dbs = []
        ; user_functions = []
        }
  in
  add_ops c oldops newops;
  c


let load host tlids newops =
  let c = create ~load:true host newops in
  c :=
    { !c with handlers =
                List.filter !c.handlers
                  ~f:(fun tl -> List.mem ~equal:(=) tlids tl.tlid)
    };
  c

let load_all host newops = create ~load:true host newops
let init = create ~load:false

let save (c : canvas) : unit =
  Serialize.save c.host c.ops


let save_test (c: canvas) : string =
  let c = minimize c in
  let host = "test-" ^ c.host in
  let file = Serialize.json_unversioned_filename host in
  let host = if File.file_exists ~root:Testdata file
             then
               host
               ^ "_"
               ^ (Unix.gettimeofday () |> int_of_float |> string_of_int)
             else host in
  let file = Serialize.json_unversioned_filename host in
  Serialize.save_json_to_disk ~root:Testdata file c.ops;
  file

(* ------------------------- *)
(* Routing *)
(* ------------------------- *)

let matching_routes ~(uri: Uri.t) ~(verb: string) (c: canvas) : (bool * Handler.handler) list =
  let path = Uri.path uri in
  c.handlers
  |> TL.http_handlers
  |> List.filter
    ~f:(fun h -> Handler.event_name_for h <> None)
  |> List.filter
    ~f:(fun h -> Http.path_matches_route ~path:path (Handler.event_name_for_exn h))
  |> List.filter
    ~f:(fun h ->
      (match Handler.modifier_for h with
        | Some m -> String.Caseless.equal m verb
        (* we specifically want to allow handlers without method specifiers for now *)
        | None -> true))
  |> List.map
    ~f:(fun h -> (Http.has_route_variables (Handler.event_name_for_exn h), h))

let pages_matching_route ~(uri: Uri.t) ~(verb: string) (c: canvas) : (bool * Handler.handler) list =
  matching_routes ~uri ~verb c



