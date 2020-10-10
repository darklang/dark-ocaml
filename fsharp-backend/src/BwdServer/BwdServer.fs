module BwdServer

open Saturn
open Giraffe.Core
open Giraffe.ResponseWriters

open LibExecution

module Route =
  let builder typeName methodName = sprintf "/api/%s/%s" typeName methodName

let webApp =
  router { not_found_handler (setStatusCode 404 >=> text "Api 404") }

let app =
  application {
    url "http://0.0.0.0:9001"
    use_router webApp
  (* use_static "public" *)
  (* use_gzip *)
  }

run app
