open Async
open Core
open Pipe_lib
open Mina_base
open Integration_test_lib
module Timeout = Timeout_lib.Core_time

(** This implements Log_engine_intf for stack driver logs for integration tests
    Assumptions:
      1. gcloud is installed and authorized to perform logging and pubsub related changes
      2. gcloud API key is set in the environment variable GCLOUD_API_KEY*)

(*Project Id is required for creating topic, sinks, and subscriptions*)
let project_id = "o1labs-192920"

let prog = "gcloud"

let load_config_json json_str =
  Malleable_error.try_with (fun () -> Yojson.Safe.from_string json_str)

let coda_container_filter = "resource.labels.container_name=\"coda\""

let block_producer_filter = "resource.labels.pod_name:\"block-producer\""

let structured_event_filter event_id =
  Printf.sprintf "jsonPayload.event_id=\"%s\""
    (Structured_log_events.string_of_id event_id)

module Subscription = struct
  type t = {name: string; topic: string; sink: string}

  (*Using the api endpoint to create a sink instead of the gcloud command
  because the cli doesn't allow setting the writerIdentity account for the sink
  and instead generates an account that doesn't have permissions to publish
  logs to the topic. The account needs to be given permissions explicitly and
  then there's this from the documentation:
    There is a delay between creating the sink and using the sink's new service
     account to authorize writing to the export destination. During the first 24
     hours after sink creation, you might see permission-related error messages
     from the sink on your project's Activity page; you can ignore them.
  *)
  let create_sink ~topic ~filter ~key ~logger name =
    let open Malleable_error.Let_syntax in
    let url =
      "https://logging.googleapis.com/v2/projects/o1labs-192920/sinks?key="
      ^ key
    in
    let%bind authorization =
      let%map token =
        Deferred.bind ~f:Malleable_error.of_or_error_hard
          (Process.run ~prog ~args:["auth"; "print-access-token"] ())
      in
      let token = String.strip token in
      String.concat ["Authorization: Bearer "; token]
    in
    let req_type = "Accept: application/json" in
    let content_type = "Content-Type: application/json" in
    let destination =
      String.concat ~sep:"/"
        ["pubsub.googleapis.com"; "projects"; project_id; "topics"; topic]
    in
    let header = "--header" in
    let data =
      `Assoc
        [ ("name", `String name)
        ; ("description", `String "Sink for tests")
        ; ("destination", `String destination)
        ; ("filter", `String filter) ]
      |> Yojson.Safe.to_string
    in
    let%bind response =
      Deferred.bind ~f:Malleable_error.of_or_error_hard
        (Process.run ~prog:"curl"
           ~args:
             [ "--request"
             ; "POST"
             ; url
             ; header
             ; authorization
             ; header
             ; req_type
             ; header
             ; content_type
             ; "--data"
             ; data
             ; "--compressed" ]
           ())
    in
    let%bind response_json = load_config_json response in
    [%log debug] "Create sink response: $response"
      ~metadata:[("response", response_json)] ;
    match
      Yojson.Safe.Util.(to_option Fn.id (member "error" response_json))
    with
    | Some _ ->
        Malleable_error.of_string_hard_error_format
          !"Error when creating sink: %s"
          response
    | None ->
        Malleable_error.ok_unit

  let create ~name ~filter ~logger =
    let open Malleable_error.Let_syntax in
    let uuid = Uuid_unix.create () in
    let name = name ^ "_" ^ Uuid.to_string uuid in
    let gcloud_key_file_env = "GCLOUD_API_KEY" in
    let%bind key =
      match Sys.getenv gcloud_key_file_env with
      | Some key ->
          return key
      | None ->
          Malleable_error.of_string_hard_error_format
            "Set environment variable %s with the service account key to use \
             Stackdriver logging"
            gcloud_key_file_env
    in
    let create_topic name =
      Deferred.bind ~f:Malleable_error.of_or_error_hard
        (Process.run ~prog ~args:["pubsub"; "topics"; "create"; name] ())
    in
    let create_subscription name topic =
      Deferred.bind ~f:Malleable_error.of_or_error_hard
        (Process.run ~prog
           ~args:
             [ "pubsub"
             ; "subscriptions"
             ; "create"
             ; name
             ; "--topic"
             ; topic
             ; "--topic-project"
             ; project_id ]
           ())
    in
    let topic = name ^ "_topic" in
    let sink = name ^ "_sink" in
    let%bind _ = create_topic topic in
    let%bind _ = create_sink ~topic ~filter ~key ~logger sink in
    let%map _ = create_subscription name topic in
    {name; topic; sink}

  let delete t =
    let delete_subscription () =
      Deferred.bind ~f:Malleable_error.of_or_error_hard
        (Process.run ~prog
           ~args:
             [ "pubsub"
             ; "subscriptions"
             ; "delete"
             ; t.name
             ; "--project"
             ; project_id ]
           ())
    in
    let delete_sink () =
      Deferred.bind ~f:Malleable_error.of_or_error_hard
        (Process.run ~prog
           ~args:["logging"; "sinks"; "delete"; t.sink; "--project"; project_id]
           ())
    in
    let delete_topic () =
      Deferred.bind ~f:Malleable_error.of_or_error_hard
        (Process.run ~prog
           ~args:
             ["pubsub"; "topics"; "delete"; t.topic; "--project"; project_id]
           ())
    in
    Malleable_error.combine_errors
      [delete_subscription (); delete_sink (); delete_topic ()]

  let pull t =
    let open Malleable_error.Let_syntax in
    let subscription_id =
      String.concat ~sep:"/" ["projects"; project_id; "subscriptions"; t.name]
    in
    (* The limit for messages we pull on each interval is currently not configurable. For now, it's set to 5 (which will hopefully be a sane for a while). *)
    let%bind result =
      Deferred.bind ~f:Malleable_error.of_or_error_hard
        (Process.run ~prog
           ~args:
             [ "pubsub"
             ; "subscriptions"
             ; "pull"
             ; subscription_id
             ; "--auto-ack"
             ; "--limit"
             ; string_of_int 5
             ; "--format"
             ; "table(DATA)" ]
           ())
    in
    match String.split_lines result with
    | [] | ["DATA"] ->
        return []
    | "DATA" :: data ->
        Malleable_error.List.map data ~f:load_config_json
    | _ ->
        Malleable_error.of_string_hard_error
          (sprintf "Invalid subscription pull result: %s" result)
end

module Json_parsing = struct
  open Yojson.Safe.Util

  let lift_json_malleable_error = function
    | Ok x ->
        Malleable_error.return x
    | Error err ->
        Malleable_error.of_string_hard_error err

  type 'a parser = Yojson.Safe.t -> 'a

  let json : Yojson.Safe.t parser = Fn.id

  let bool : bool parser = to_bool

  let string : string parser = to_string

  let int : int parser =
   fun x -> try to_int x with Type_error _ -> int_of_string (to_string x)

  let float : float parser =
   fun x -> try to_float x with Type_error _ -> float_of_string (to_string x)

  let list : 'a parser -> 'a list parser = fun f x -> List.map ~f (to_list x)

  let state_hash : State_hash.t parser =
    Fn.compose Result.ok_or_failwith State_hash.of_yojson

  let parse (parser : 'a parser) (json : Yojson.Safe.t) : 'a Malleable_error.t
      =
    try Malleable_error.return (parser json)
    with exn ->
      Malleable_error.of_string_hard_error
        (Printf.sprintf "failed to parse json value: %s" (Exn.to_string exn))

  let parser_from_of_yojson of_yojson js =
    match of_yojson js with
    | Ok cmd ->
        cmd
    | Error modl ->
        let logger = Logger.create () in
        [%log error] "Could not parse JSON using of_yojson"
          ~metadata:[("module", `String modl); ("json", js)] ;
        failwithf "Could not parse JSON using %s.of_yojson" modl ()

  let valid_commands_with_statuses :
      Mina_base.User_command.Valid.t Mina_base.With_status.t list parser =
    function
    | `List cmds ->
        let cmd_or_errors =
          List.map cmds
            ~f:
              (Mina_base.With_status.of_yojson
                 Mina_base.User_command.Valid.of_yojson)
        in
        List.fold cmd_or_errors ~init:[] ~f:(fun accum cmd_or_err ->
            match (accum, cmd_or_err) with
            | _, Error err ->
                let logger = Logger.create () in
                [%log error]
                  ~metadata:[("error", `String err)]
                  "Failed to parse JSON for user command status" ;
                (* fail on any error *)
                failwith
                  "valid_commands_with_statuses: unable to parse JSON for \
                   user command"
            | cmds, Ok cmd ->
                cmd :: cmds )
    | _ ->
        failwith "valid_commands_with_statuses: expected `List"

  let rec find (parser : 'a parser) (json : Yojson.Safe.t) (path : string list)
      : 'a Malleable_error.t =
    let open Malleable_error.Let_syntax in
    match (path, json) with
    | [], _ ->
        parse parser json
    (* | [], _ -> (
      try Malleable_error.return (parser json)
      with exn ->
        Malleable_error.of_string_hard_error
          (Printf.sprintf "failed to parse json value: %s" (Exn.to_string exn))
      ) *)
    | key :: path', `Assoc assoc ->
        let%bind entry =
          Malleable_error.of_option_hard
            (List.Assoc.find assoc key ~equal:String.equal)
            (sprintf "failed to find path using key '%s' in json object { %s }"
               key
               (String.concat ~sep:", "
                  (List.map assoc ~f:(fun (s, json) ->
                       sprintf "\"%s\":%s" s (Yojson.Safe.to_string json) ))))
        in
        find parser entry path'
    | _ ->
        Malleable_error.of_error_hard
          (Error.of_string "expected json object when searching for path")
end

module type Query_intf = sig
  module Result : sig
    type t
  end

  val name : string

  val filter : string -> string

  val parse : Yojson.Safe.t -> Result.t Malleable_error.t
end

module Error_query = struct
  module Result = struct
    type t = {pod_id: string; message: Logger.Message.t}
  end

  let name = "error"

  let filter testnet_log_filter =
    String.concat ~sep:"\n"
      [ testnet_log_filter
      ; coda_container_filter
      ; "jsonPayload.level=(\"Warn\" OR \"Error\" OR \"Faulty_peer\" OR \
         \"Fatal\")" ]

  let parse log =
    let open Json_parsing in
    let open Malleable_error.Let_syntax in
    let%bind pod_id = find string log ["labels"; "k8s-pod/app"] in
    let%bind payload = find json log ["jsonPayload"] in
    let%map message =
      lift_json_malleable_error (Logger.Message.of_yojson payload)
    in
    {Result.pod_id; message}
end

module Initialization_query = struct
  module Result = struct
    type t = {pod_id: string}
  end

  let name = "initialization"

  (* TODO: this is technically the participation query right now; this can retrigger if bootstrap is toggled *)
  let filter testnet_log_filter =
    (*TODO: Structured logging: Block Produced*)
    String.concat ~sep:"\n"
      [ testnet_log_filter
      ; coda_container_filter
      ; structured_event_filter
          Transition_router
          .starting_transition_frontier_controller_structured_events_id ]

  let parse log =
    let open Json_parsing in
    let open Malleable_error.Let_syntax in
    let%map pod_id = find string log ["labels"; "k8s-pod/app"] in
    {Result.pod_id}
end

module Transition_frontier_diff_application_query = struct
  module Result = struct
    type root_transitioned =
      {new_root: State_hash.t; garbage: State_hash.t list}

    type t =
      { pod_id: string
      ; new_node: State_hash.t option
      ; best_tip_changed: State_hash.t option
      ; root_transitioned: root_transitioned option }
    [@@deriving lens]

    let empty pod_id =
      {pod_id; new_node= None; best_tip_changed= None; root_transitioned= None}

    let register (lens : (t, 'a option) Lens.t) (result : t) (x : 'a) :
        t Malleable_error.t =
      match lens.get result with
      | Some _ ->
          Malleable_error.of_string_hard_error
            "same transition frontier diff type unexpectedly encountered \
             twice in single application"
      | None ->
          Malleable_error.return (lens.set (Some x) result)
  end

  let name = "transition_frontier_diff_application"

  let filter testnet_log_filter =
    String.concat ~sep:"\n"
      [ testnet_log_filter
      ; coda_container_filter
      ; structured_event_filter
          Transition_frontier.applying_diffs_structured_events_id ]

  let parse log =
    let open Json_parsing in
    let open Result in
    let open Malleable_error.Let_syntax in
    let%bind pod_id = find string log ["labels"; "k8s-pod/app"] in
    let%bind diffs =
      find (list json) log ["jsonPayload"; "metadata"; "diffs"]
    in
    Malleable_error.List.fold diffs ~init:(Result.empty pod_id)
      ~f:(fun res diff ->
        match Yojson.Safe.Util.keys diff with
        | [name] -> (
            let%bind value = find json diff [name] in
            match name with
            | "New_node" ->
                let%bind state_hash = parse state_hash value in
                register new_node res state_hash
            | "Best_tip_changed" ->
                let%bind state_hash = parse state_hash value in
                register best_tip_changed res state_hash
            | "Root_transitioned" ->
                let%bind new_root = find state_hash value ["new_root"] in
                let%bind garbage = find (list state_hash) value ["garbage"] in
                let data = {new_root; garbage} in
                register root_transitioned res data
            | _ ->
                Malleable_error.of_string_hard_error
                  "unexpected transition frontier diff name" )
        | _ ->
            Malleable_error.of_string_hard_error
              "unexpected transition frontier diff format" )
end

module Block_produced_query = struct
  module Result = struct
    module T = struct
      type t =
        { block_height: int
        ; epoch: int
        ; global_slot: int
        ; snarked_ledger_generated: bool }
      [@@deriving to_yojson]
    end

    include T

    let empty =
      { block_height= 0
      ; epoch= 0
      ; global_slot= 0
      ; snarked_ledger_generated= false }

    (*Aggregated values for determining timeout conditions. Note: Slots passed and epochs passed are only determined if we produce a block. Add a log for these events to calculate these independently?*)
    module Aggregated = struct
      type t =
        { last_seen_result: T.t
        ; blocks_generated: int
        ; snarked_ledgers_generated: int }
      [@@deriving to_yojson]

      let empty =
        { last_seen_result= empty
        ; blocks_generated= 0
        ; snarked_ledgers_generated= 0 }

      let init (result : T.t) =
        { last_seen_result= result
        ; blocks_generated= 1
        ; snarked_ledgers_generated=
            (if result.snarked_ledger_generated then 1 else 0) }
    end

    (* TODO: Reorg will mess up the value of snarked_ledgers_generated*)
    let aggregate (aggregated : Aggregated.t) (result : t) : Aggregated.t =
      if result.block_height > aggregated.last_seen_result.block_height then
        { Aggregated.last_seen_result= result
        ; blocks_generated= aggregated.blocks_generated + 1
        ; snarked_ledgers_generated=
            ( if result.snarked_ledger_generated then
              aggregated.snarked_ledgers_generated + 1
            else aggregated.snarked_ledgers_generated ) }
      else aggregated
  end

  let filter testnet_log_filter =
    (*TODO: Structured logging: Block Produced*)
    String.concat ~sep:"\n"
      [ testnet_log_filter
      ; block_producer_filter
      ; coda_container_filter
      ; structured_event_filter
          Block_producer.block_produced_structured_events_id ]

  (*TODO: Once we transition to structured events, this should call Structured_log_event.parse_exn and match on the structured events that it returns.*)
  let parse log =
    let open Json_parsing in
    let open Malleable_error.Let_syntax in
    let breadcrumb = ["jsonPayload"; "metadata"; "breadcrumb"] in
    let breadcrumb_consensus_state =
      breadcrumb
      @ [ "validated_transition"
        ; "data"
        ; "protocol_state"
        ; "body"
        ; "consensus_state" ]
    in
    let%bind snarked_ledger_generated =
      find bool log (breadcrumb @ ["just_emitted_a_proof"])
    in
    let%bind block_height =
      find int log (breadcrumb_consensus_state @ ["blockchain_length"])
    in
    let%bind global_slot =
      find int log
        (breadcrumb_consensus_state @ ["curr_global_slot"; "slot_number"])
    in
    let%map epoch =
      find int log (breadcrumb_consensus_state @ ["epoch_count"])
    in
    {Result.block_height; global_slot; epoch; snarked_ledger_generated}
end

module Breadcrumb_added_query = struct
  open Mina_base

  module Result = struct
    type t = {user_commands: User_command.Valid.t With_status.t list}
  end

  let filter testnet_log_filter =
    String.concat ~sep:"\n"
      [ testnet_log_filter
      ; coda_container_filter
      ; structured_event_filter
          Transition_frontier
          .added_breadcrumb_user_commands_structured_events_id ]

  let parse js : Result.t Malleable_error.t =
    let open Json_parsing in
    let open Malleable_error.Let_syntax in
    (* JSON path to metadata entry *)
    let path = ["jsonPayload"; "metadata"; "user_commands"] in
    let parser = valid_commands_with_statuses in
    let%map user_commands = find parser js path in
    Result.{user_commands}
end

type errors =
  { warn: Error_query.Result.t DynArray.t
  ; error: Error_query.Result.t DynArray.t
  ; faulty_peer: Error_query.Result.t DynArray.t
  ; fatal: Error_query.Result.t DynArray.t }

let empty_errors () =
  { warn= DynArray.create ()
  ; error= DynArray.create ()
  ; faulty_peer= DynArray.create ()
  ; fatal= DynArray.create () }

type subscriptions =
  { errors: Subscription.t
  ; initialization: Subscription.t
  ; blocks_produced: Subscription.t
  ; transition_frontier_diff_application: Subscription.t
  ; breadcrumb_added: Subscription.t }

type t =
  { logger: Logger.t
  ; testnet_log_filter: string
  ; constants: constants
  ; subscriptions: subscriptions
  ; cancel_background_tasks: unit -> unit Deferred.t
  ; error_accumulator: errors
  ; initialization_table: unit Ivar.t String.Map.t
  ; best_tip_map_reader: State_hash.t String.Map.t Broadcast_pipe.Reader.t
  ; best_tip_map_writer: State_hash.t String.Map.t Broadcast_pipe.Writer.t }

let delete_subscriptions
    { errors
    ; initialization
    ; blocks_produced
    ; transition_frontier_diff_application
    ; breadcrumb_added } =
  Malleable_error.combine_errors
    [ Subscription.delete errors
    ; Subscription.delete initialization
    ; Subscription.delete blocks_produced
    ; Subscription.delete transition_frontier_diff_application
    ; Subscription.delete breadcrumb_added ]

let rec pull_subscription_in_background ~logger ~subscription_name
    ~parse_subscription ~subscription ~handle_result =
  let open Interruptible in
  let open Interruptible.Let_syntax in
  let%bind results =
    uninterruptible
      (let open Malleable_error.Let_syntax in
      let%bind logs = Subscription.pull subscription in
      Malleable_error.List.map logs ~f:parse_subscription)
  in
  [%log debug] "Pulling subscription $subscription_name"
    ~metadata:[("subscription_name", `String subscription_name)] ;
  let%bind () =
    uninterruptible
      ( match results with
      | Error err ->
          Error.raise err.hard_error.error
      | Ok res ->
          Deferred.List.iter res.computation_result
            ~f:(Fn.compose Malleable_error.ok_exn handle_result) )
  in
  let%bind () = uninterruptible (after (Time.Span.of_ms 10000.0)) in
  (* this extra bind point allows the interruptible monad to interrupt after the timeout *)
  let%bind () = return () in
  pull_subscription_in_background ~logger ~subscription_name
    ~parse_subscription ~subscription ~handle_result

let start_background_query (type r)
    (module Query : Query_intf with type Result.t = r) ~logger
    ~testnet_log_filter ~cancel_ivar
    ~(handle_result : r -> unit Malleable_error.t) =
  let open Interruptible in
  let open Malleable_error.Let_syntax in
  let finished_ivar = Ivar.create () in
  let%map subscription =
    Subscription.create ~logger ~name:Query.name
      ~filter:(Query.filter testnet_log_filter)
  in
  [%log info] "Subscription created for background query $query"
    ~metadata:[("query", `String Query.name)] ;
  let subscription_task =
    let open Interruptible.Let_syntax in
    let%bind () = lift Deferred.unit (Ivar.read cancel_ivar) in
    pull_subscription_in_background ~logger ~subscription_name:Query.name
      ~parse_subscription:Query.parse ~subscription ~handle_result
  in
  don't_wait_for
    (finally subscription_task ~f:(fun () ->
         if Ivar.is_full finished_ivar then
           [%log error] "Ivar.fill bug is here!" ;
         Ivar.fill finished_ivar () )) ;
  (subscription, Ivar.read finished_ivar)

let create ~logger ~(network : Kubernetes_network.t) ~on_fatal_error =
  let open Malleable_error.Let_syntax in
  let%bind blocks_produced =
    Subscription.create ~logger ~name:"blocks_produced"
      ~filter:(Block_produced_query.filter network.testnet_log_filter)
  in
  [%log info] "Subscription created for blocks produced" ;
  let%bind breadcrumb_added =
    Subscription.create ~logger ~name:"breadcrumb_added"
      ~filter:(Breadcrumb_added_query.filter network.testnet_log_filter)
  in
  [%log info] "Subscription created for breadcrumbs added" ;
  let cancel_background_tasks_ivar = Ivar.create () in
  let error_accumulator = empty_errors () in
  let%bind errors, errors_task_finished =
    start_background_query
      (module Error_query)
      ~logger ~testnet_log_filter:network.testnet_log_filter
      ~cancel_ivar:cancel_background_tasks_ivar
      ~handle_result:(fun result ->
        let open Error_query.Result in
        let acc =
          match result.message.level with
          | Warn ->
              error_accumulator.warn
          | Error ->
              error_accumulator.error
          | Faulty_peer ->
              error_accumulator.faulty_peer
          | Fatal ->
              error_accumulator.fatal
          | _ ->
              failwith "unexpected log level encountered"
        in
        DynArray.add acc result ;
        if result.message.level = Fatal then (
          [%log fatal] "Error occured $error"
            ~metadata:[("error", Logger.Message.to_yojson result.message)] ;
          on_fatal_error result.message ) ;
        Malleable_error.return () )
  in
  let initialization_table =
    let open Kubernetes_network.Node in
    Kubernetes_network.all_nodes network
    |> List.map ~f:(fun (node : Kubernetes_network.Node.t) ->
           (node.pod_id, Ivar.create ()) )
    |> String.Map.of_alist_exn
  in
  let%bind initialization, initialization_task_finished =
    start_background_query
      (module Initialization_query)
      ~logger ~testnet_log_filter:network.testnet_log_filter
      ~cancel_ivar:cancel_background_tasks_ivar
      ~handle_result:(fun result ->
        let open Initialization_query.Result in
        let open Malleable_error.Let_syntax in
        let%bind ivar =
          (* TEMP hack, this probably should be of_option_hard *)
          Malleable_error.of_option_soft
            (String.Map.find initialization_table result.pod_id)
            (Printf.sprintf "Node not found in initialization table: %s"
               result.pod_id)
            (Ivar.create ())
        in
        if Ivar.is_empty ivar then ( Ivar.fill ivar () ; return () )
        else (
          [%log warn]
            "Received initialization for node that has already initialized" ;
          return () ) )
  in
  let best_tip_map_reader, best_tip_map_writer =
    Broadcast_pipe.create String.Map.empty
  in
  let%map ( transition_frontier_diff_application
          , transition_frontier_diff_application_finished ) =
    start_background_query
      (module Transition_frontier_diff_application_query)
      ~logger ~testnet_log_filter:network.testnet_log_filter
      ~cancel_ivar:cancel_background_tasks_ivar
      ~handle_result:(fun result ->
        let open Transition_frontier_diff_application_query.Result in
        Option.value_map result.best_tip_changed
          ~default:Malleable_error.ok_unit ~f:(fun new_best_tip ->
            let open Malleable_error.Let_syntax in
            let best_tip_map =
              Broadcast_pipe.Reader.peek best_tip_map_reader
            in
            let best_tip_map' =
              String.Map.set best_tip_map ~key:result.pod_id ~data:new_best_tip
            in
            let%map () =
              Deferred.bind ~f:Malleable_error.return
                (Broadcast_pipe.Writer.write best_tip_map_writer best_tip_map')
            in
            () ) )
  in
  let cancel_background_tasks () =
    let open Deferred.Let_syntax in
    if not (Ivar.is_full cancel_background_tasks_ivar) then
      Ivar.fill cancel_background_tasks_ivar () ;
    let%map () =
      Deferred.all_unit
        [ errors_task_finished
        ; initialization_task_finished
        ; transition_frontier_diff_application_finished ]
    in
    [%log debug] "cancel_background_tasks finished"
  in
  { testnet_log_filter= network.testnet_log_filter
  ; logger
  ; constants=
      { constraints= network.constraint_constants
      ; genesis= network.genesis_constants }
  ; subscriptions=
      { errors
      ; initialization
      ; blocks_produced
      ; transition_frontier_diff_application
      ; breadcrumb_added }
  ; cancel_background_tasks
  ; error_accumulator
  ; initialization_table
  ; best_tip_map_writer
  ; best_tip_map_reader }

let destroy t : Test_error.Set.t Malleable_error.t =
  let open Malleable_error.Let_syntax in
  let { testnet_log_filter= _
      ; constants= _
      ; logger= _
      ; subscriptions
      ; cancel_background_tasks
      ; initialization_table= _
      ; best_tip_map_reader= _
      ; best_tip_map_writer
      ; error_accumulator } =
    t
  in
  let%bind () =
    Deferred.bind (cancel_background_tasks ()) ~f:Malleable_error.return
  in
  Broadcast_pipe.Writer.close best_tip_map_writer ;
  let logger = Logger.create () in
  let%map _ = delete_subscriptions subscriptions in
  [%log debug] "subscriptions deleted" ;
  let lift error_array =
    DynArray.to_list error_array
    |> List.map ~f:(fun {Error_query.Result.pod_id; message} ->
           Test_error.Remote_error {node_id= pod_id; error_message= message} )
  in
  let soft_errors =
    lift error_accumulator.warn @ lift error_accumulator.faulty_peer
  in
  let hard_errors =
    lift error_accumulator.error @ lift error_accumulator.fatal
  in
  {Test_error.Set.soft_errors; hard_errors}

let wait_for' :
       t
    -> Condition.t
    -> ( [> `Blocks_produced of int]
       * [> `Slots_passed of int]
       * [> `Snarked_ledgers_generated of int] )
       Malleable_error.t =
 fun t cond ->
  let finished = Ivar.create () in
  let stop = Ivar.read finished in
  let updates =
    let r, w = Pipe.create () in
    upon stop (fun () -> if not (Pipe.is_closed w) then Pipe.close w) ;
    let timeouts = ref [] in
    let finish () =
      Ivar.fill_if_empty finished () ;
      List.iter !timeouts ~f:(fun e -> Clock.Event.abort_if_possible e ()) ;
      if not (Pipe.is_closed w) then Pipe.close w
    in
    let add_timeout time x =
      Option.iter (Network_time_span.to_span ~constants:t.constants time)
        ~f:(fun span ->
          timeouts :=
            Clock.Event.run_after span
              (fun () ->
                Pipe.write_without_pushback_if_open w x ;
                finish () )
              ()
            :: !timeouts )
    in
    add_timeout cond.hard_timeout
      (Error
         { Malleable_error.Hard_fail.hard_error=
             Test_error.raw_internal_error (Error.of_string "timed out")
         ; soft_errors= [] }) ;
    add_timeout cond.soft_timeout
      (Ok
         { Malleable_error.Accumulator.computation_result= []
         ; soft_errors=
             [Test_error.raw_internal_error (Error.of_string "soft timeout")]
         }) ;
    let interval =
      Time.Span.of_ms
        (Int.to_float t.constants.constraints.block_window_duration_ms /. 2.0)
    in
    Clock.every' ~stop interval (fun () ->
        [%log' info t.logger] "Pulling blocks produced subscription" ;
        let%bind res = Subscription.pull t.subscriptions.blocks_produced in
        let d = Pipe.write_if_open w res in
        ( match res with
        | Ok {computation_result= logs; _} ->
            [%log' info t.logger]
              ~metadata:[("n", `Int (List.length logs)); ("logs", `List logs)]
              "Pulled $n logs for blocks produced: $logs"
        | Error _ ->
            finish () ) ;
        d ) ;
    r
  in
  let conditions_passed (acc : Block_produced_query.Result.Aggregated.t) =
    cond.predicate
      { block_height= acc.last_seen_result.block_height
      ; epoch= acc.last_seen_result.epoch
      ; global_slot= acc.last_seen_result.global_slot
      ; snarked_ledgers_generated= acc.snarked_ledgers_generated
      ; blocks_generated= acc.blocks_generated }
  in
  let rec go acc =
    let finish (acc : Block_produced_query.Result.Aggregated.t) =
      Ivar.fill_if_empty finished () ;
      Malleable_error.return
        ( `Blocks_produced acc.blocks_generated
        , `Slots_passed acc.last_seen_result.global_slot
        , `Snarked_ledgers_generated acc.snarked_ledgers_generated )
    in
    match%bind Pipe.read updates with
    | `Eof ->
        finish acc
    | `Ok r ->
        let open Malleable_error.Let_syntax in
        let%bind logs = Deferred.return r in
        let%bind finished, acc =
          Malleable_error.List.fold_left_while logs ~init:(false, acc)
            ~f:(fun (_, acc) log ->
              let open Malleable_error.Let_syntax in
              let%map result = Block_produced_query.parse log in
              let acc = Block_produced_query.Result.aggregate acc result in
              if conditions_passed acc then `Stop (true, acc)
              else `Continue (false, acc) )
        in
        if finished then finish acc else go acc
  in
  go Block_produced_query.Result.Aggregated.empty

let wait_for t cond =
  match%bind wait_for' t cond with
  | Error {Malleable_error.Hard_fail.hard_error= e; soft_errors= se} ->
      [%log' fatal t.logger] "wait_for failed with error: $error"
        ~metadata:[("error", Error_json.error_to_yojson e.error)] ;
      Deferred.return
        (Error {Malleable_error.Hard_fail.hard_error= e; soft_errors= se})
  | res ->
      Deferred.return res

let command_matches_payment cmd ~sender ~receiver ~amount =
  let open User_command in
  match cmd with
  | Signed_command signed_cmd -> (
      let open Signature_lib in
      let body =
        Signed_command.payload signed_cmd |> Signed_command_payload.body
      in
      match body with
      | Payment {source_pk; receiver_pk; amount= paid_amt; token_id= _}
        when Public_key.Compressed.equal source_pk sender
             && Public_key.Compressed.equal receiver_pk receiver
             && Currency.Amount.equal paid_amt amount ->
          true
      | _ ->
          false )
  | Snapp_command _ ->
      false

let wait_for_payment ?(num_tries = 30) t ~logger ~sender ~receiver ~amount () :
    unit Malleable_error.t =
  let retry_delay_sec = 30.0 in
  let rec go n =
    if n <= 0 then
      Malleable_error.of_string_hard_error
        (sprintf
           "wait_for_payment: did not find matching payment after %d trie(s)"
           num_tries)
    else
      let%bind results =
        let open Malleable_error.Let_syntax in
        let%bind user_cmds_json =
          Subscription.pull t.subscriptions.breadcrumb_added
        in
        Malleable_error.List.map user_cmds_json ~f:Breadcrumb_added_query.parse
      in
      match results with
      | Error
          { Malleable_error.Hard_fail.hard_error= err
          ; Malleable_error.Hard_fail.soft_errors= _ } ->
          Error.raise err.error
      | Ok {Malleable_error.Accumulator.computation_result= []; soft_errors= _}
        ->
          [%log info] "wait_for_payment: no added breadcrumbs, trying again" ;
          let%bind () = after Time.Span.(of_sec retry_delay_sec) in
          go (n - 1)
      | Ok {Malleable_error.Accumulator.computation_result= res; soft_errors= _}
        ->
          let open Mina_base in
          let open Signature_lib in
          (* res is a list of Breadcrumb_added_query.Result.t
             each of those contains a list of user commands
          *)
          let payment_opt =
            List.fold res ~init:None ~f:(fun acc {user_commands} ->
                if Option.is_some acc then acc
                else
                  List.find user_commands
                    ~f:(fun (cmd_with_status :
                              User_command.Valid.t With_status.t)
                       ->
                      cmd_with_status.With_status.data
                      |> User_command.forget_check
                      |> command_matches_payment ~sender ~receiver ~amount ) )
          in
          if Option.is_some payment_opt then
            let cmd_with_status = Option.value_exn payment_opt in
            let actual_status = cmd_with_status.With_status.status in
            let applied =
              match actual_status with
              | Transaction_status.Applied _ ->
                  true
              | _ ->
                  false
            in
            if applied then (
              [%log info] "wait_for_payment: found matching payment"
                ~metadata:
                  [ ("sender", `String (Public_key.Compressed.to_string sender))
                  ; ( "receiver"
                    , `String (Public_key.Compressed.to_string receiver) )
                  ; ("amount", `String (Currency.Amount.to_string amount)) ] ;
              Malleable_error.return () )
            else (
              [%log info]
                "wait_for_payment: found matching payment, but status is not \
                 'Applied'"
                ~metadata:
                  [ ("sender", `String (Public_key.Compressed.to_string sender))
                  ; ( "receiver"
                    , `String (Public_key.Compressed.to_string receiver) )
                  ; ("amount", `String (Currency.Amount.to_string amount))
                  ; ( "actual_user_command_status"
                    , Transaction_status.to_yojson actual_status ) ] ;
              Error.raise
                (Error.of_string
                   (sprintf "Unexpected status in matching payment: %s"
                      ( Transaction_status.to_yojson actual_status
                      |> Yojson.Safe.to_string ))) )
          else (
            [%log info]
              "wait_for_payment: found added breadcrumbs, but did not find \
               matching payment" ;
            let%bind () = after Time.Span.(of_sec retry_delay_sec) in
            go (n - 1) )
  in
  go num_tries

let await_timeout ~waiting_for ~timeout_duration ~logger deferred =
  match%bind Timeout.await ~timeout_duration () deferred with
  | `Timeout ->
      Malleable_error.of_string_hard_error_format
        "timeout while waiting for %s" waiting_for
  | `Ok x ->
      [%log info] "%s completed" waiting_for ;
      Malleable_error.return x

let wait_for_init (node : Kubernetes_network.Node.t) t =
  let open Malleable_error.Let_syntax in
  [%log' info t.logger]
    ~metadata:[("node", `String node.pod_id)]
    "Waiting for $node to initialize" ;
  let%bind init =
    Malleable_error.of_option_hard
      (String.Map.find t.initialization_table node.pod_id)
      "failed to find node in initialization table"
  in
  if Ivar.is_full init then return ()
  else
    (* TODO: make configurable (or ideally) compute dynamically from network configuration *)
    await_timeout ~waiting_for:"initialization"
      ~timeout_duration:(Time.Span.of_ms (15.0 *. 60.0 *. 1000.0))
      (Ivar.read init) ~logger:t.logger

let wait_for_sync (nodes : Kubernetes_network.Node.t list) ~timeout t =
  [%log' info t.logger]
    ~metadata:[("nodes", `List (List.map ~f:(fun n -> `String n.pod_id) nodes))]
    "Waiting for $nodes to synchronize" ;
  let pod_ids = List.map nodes ~f:(fun node -> node.pod_id) in
  let all_equal ls =
    Option.value_map (List.hd ls) ~default:true ~f:(fun h ->
        [h] = List.find_all_dups ~compare:State_hash.compare ls )
  in
  let all_nodes_synced best_tip_map =
    if List.for_all pod_ids ~f:(String.Map.mem best_tip_map) then
      (* [lookup_exn] should never throw an exception here *)
      all_equal (List.map pod_ids ~f:(String.Map.find_exn best_tip_map))
    else false
  in
  [%log' info t.logger] "waiting for %f seconds" (Time.Span.to_sec timeout) ;
  await_timeout
    (Broadcast_pipe.Reader.iter_until t.best_tip_map_reader
       ~f:(Fn.compose Deferred.return all_nodes_synced))
    ~waiting_for:"synchronization" ~timeout_duration:timeout ~logger:t.logger

(*TODO: unit tests without conencting to gcloud. The following test connects to joyous-occasion*)
(*let%test_module "Log tests" =
  ( module struct
    let logger = Logger.create ()

    let testnet : Kubernetes_network.t =
      let k8 = "k8s_container" in
      let location = "us-east1" in
      let cluster_name = "coda-infra-east" in
      let testnet_name = "joyous-occasion" in
      { block_producers= []
      ; snark_coordinators= []
      ; archive_nodes= []
      ; testnet_log_filter=
          String.concat ~sep:" "
            [ "resource.type="
            ; k8
            ; "resource.labels.location="
            ; location
            ; "resource.labels.cluster_name="
            ; cluster_name
            ; "resource.labels.namespace_name="
            ; testnet_name ] }

    let wait_for_block_height () =
      let open Deferred.Or_error.Let_syntax in
      let%bind log_engine = create ~logger testnet in
      let%bind _ = wait_for ~blocks:2500 log_engine in
      delete log_engine

    let wait_for_slot_timeout () =
      let open Deferred.Or_error.Let_syntax in
      let%bind log_engine = create ~logger testnet in
      let%bind _ = wait_for ~timeout:(`Slots 2) log_engine in
      delete log_engine

    let wait_for_epoch () =
      let open Deferred.Or_error.Let_syntax in
      let%bind log_engine = create ~logger testnet in
      let%bind _ = wait_for ~epoch_reached:16 log_engine in
      delete log_engine

    let test_exn f () =
      let%map res = f () in
      Or_error.ok_exn res

    let%test_unit "joyous-occasion - wait_for_block_height" =
      Async.Thread_safe.block_on_async_exn (test_exn wait_for_block_height)

    let%test_unit "joyous-occasion - wait_for_slot_timeout" =
      Async.Thread_safe.block_on_async_exn (test_exn wait_for_slot_timeout)

    let%test_unit "joyous-occasion - wait_for_epoch" =
      Async.Thread_safe.block_on_async_exn (test_exn wait_for_epoch)
  end )*)
