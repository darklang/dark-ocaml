/// API endpoints to function and Handler execution
module ApiServer.Execution

open System.Threading.Tasks
open FSharp.Control.Tasks
open Microsoft.AspNetCore.Http

open Prelude
open Tablecloth
open Http

module PT = LibExecution.ProgramTypes
module PTParser = LibExecution.ProgramTypesParser
module RT = LibExecution.RuntimeTypes
module OT = LibExecution.OCamlTypes
module ORT = LibExecution.OCamlTypes.RuntimeT
module PT2RT = LibExecution.ProgramTypesToRuntimeTypes
module AT = LibExecution.AnalysisTypes
module Convert = LibExecution.OCamlTypes.Convert

module Canvas = LibBackend.Canvas
module RealExe = LibRealExecution.RealExecution
module Exe = LibExecution.Execution
module DvalReprInternalDeprecated = LibExecution.DvalReprInternalDeprecated
module Telemetry = LibService.Telemetry

module Function =
  type Params =
    { tlid : tlid
      trace_id : AT.TraceID
      caller_id : id
      args : ORT.dval list
      fnname : string }

  type T =
    { result : ORT.dval
      hash : string
      hashVersion : int
      touched_tlids : tlid list
      unlocked_dbs : tlid list }

  /// API endpoint to execute a User Function and return the result
  let execute (ctx : HttpContext) : Task<T> =
    task {
      use t = startTimer "read-api" ctx
      let canvasInfo = loadCanvasInfo ctx
      let executionID = loadExecutionID ctx
      let! p = ctx.ReadJsonAsync<Params>()
      let args = List.map Convert.ocamlDval2rt p.args
      Telemetry.addTags [ "tlid", p.tlid
                          "trace_id", p.trace_id
                          "caller_id", p.caller_id
                          "fnname", p.fnname ]

      t.next "load-canvas"
      let! c = Canvas.loadTLIDsWithContext canvasInfo [ p.tlid ]

      t.next "load-execution-state"
      let program = Canvas.toProgram c
      let! (state, traceResult) =
        RealExe.createState executionID p.trace_id p.tlid program

      t.next "execute-function"
      let fnname = p.fnname |> PTParser.FQFnName.parse |> PT2RT.FQFnName.toRT
      let! result = Exe.executeFunction state p.caller_id args fnname
      RealExe.traceResultHook canvasInfo.id p.trace_id executionID traceResult

      t.next "get-unlocked"
      let! unlocked = LibBackend.UserDB.unlocked canvasInfo.owner canvasInfo.id

      t.next "write-api"
      let hashVersion = DvalReprInternalDeprecated.currentHashVersion
      let hash = DvalReprInternalDeprecated.hash hashVersion args

      let result =
        { result = Convert.rt2ocamlDval result
          hash = hash
          hashVersion = hashVersion
          touched_tlids = HashSet.toList traceResult.tlids
          unlocked_dbs = unlocked }

      return result
    }

module Handler =
  type Params =
    { tlid : tlid
      trace_id : AT.TraceID
      input : List<string * ORT.dval> }

  type T = { touched_tlids : tlid list }

  /// API endpoint to trigger the execution of a Handler
  ///
  /// Handlers are handled asynchronously, so the result is not returned
  let trigger (ctx : HttpContext) : Task<T> =
    task {
      use t = startTimer "read-api" ctx
      let executionID = loadExecutionID ctx
      let canvasInfo = loadCanvasInfo ctx
      let! p = ctx.ReadJsonAsync<Params>()
      Telemetry.addTags [ "tlid", p.tlid; "trace_id", p.trace_id ]

      let inputVars =
        p.input
        |> List.map (fun (name, var) -> (name, Convert.ocamlDval2rt var))
        |> Map.ofList

      t.next "load-canvas"
      let! c = Canvas.loadTLIDsWithContext canvasInfo [ p.tlid ]
      let program = Canvas.toProgram c
      let expr = c.handlers[p.tlid].ast |> PT2RT.Expr.toRT

      t.next "load-execution-state"
      let! state, traceResult =
        RealExe.createState executionID p.trace_id p.tlid program

      t.next "execute-handler"
      // CLEANUP
      // since this ignores the result, it doesn't go through the http result
      // handling function. This might not matter
      let! (_result : RT.Dval) = Exe.executeHandler state inputVars expr
      RealExe.traceResultHook canvasInfo.id p.trace_id executionID traceResult

      t.next "write-api"
      return { touched_tlids = traceResult.tlids |> HashSet.toList }
    }
