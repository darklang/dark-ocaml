open Prelude

let markRequestInModel ~(key : string) (m : model) : model =
  let syncState = Set.add m.syncState ~value:key in
  {m with syncState}


let markResponseInModel ~(key : string) (m : model) : model =
  let syncState = Set.remove m.syncState ~value:key in
  {m with syncState}


let inFlight ~(key : string) (m : model) : bool =
  Set.member m.syncState ~value:key


let attempt ?(force = false) ~(key : string) (m : model) (cmd : msg Tea.Cmd.t) :
    model * msg Tea.Cmd.t =
  if inFlight m ~key && not force
  then (m, Tea.Cmd.none)
  else (markRequestInModel m ~key, cmd)
