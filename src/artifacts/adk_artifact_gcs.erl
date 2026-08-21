%% @doc Immutable, exactly-scoped artifact service backed by Google Cloud
%% Storage-compatible object operations.
%%
%% Logical scopes and names are never used as object-name components. Each is
%% represented by a deterministic SHA-256 token and every loaded manifest is
%% checked against the exact requested identity. A create-only reservation
%% allocates a version, data is written create-only, and the create-only
%% manifest is the publication point.
-module(adk_artifact_gcs).
-behaviour(adk_artifact_service).
-behaviour(gen_server).

-export([
    start_link/1,
    capabilities/1,
    put/5, put/6,
    get/4, get/5,
    get_range/6,
    list/2,
    list_names/3,
    list_versions/4,
    delete/4, delete/5,
    start_upload/5,
    start_download/5,
    stop/1
]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(DEFAULT_CALL_TIMEOUT_MS, 30000).
-define(DEFAULT_MAX_ARTIFACT_BYTES, 64 * 1024 * 1024).
-define(DEFAULT_MAX_PAGE_LIMIT, 1000).
-define(DEFAULT_LEGACY_LIST_LIMIT, 1000).
-define(DEFAULT_MAX_SCAN_ENTRIES, 10000).
-define(DEFAULT_MAX_CONCURRENCY, 32).
-define(DEFAULT_MAX_RESERVATION_ATTEMPTS, 1024).
-define(DEFAULT_STREAM_CHUNK_BYTES, 64 * 1024).
-define(DEFAULT_STREAM_CREDIT_MESSAGES, 8).
-define(DEFAULT_STREAM_TIMEOUT_MS, 30000).
-define(MAX_METADATA_BYTES, 65536).
-define(MAX_OBJECT_NAME_BYTES, 2048).
-define(OPERATION_MAX_HEAP_WORDS, 33554432).
-define(MAX_CONFIG_ARTIFACT_BYTES, 128 * 1024 * 1024).
-define(MAX_CONFIG_PAGE_LIMIT, 10000).
-define(MAX_CONFIG_SCAN_ENTRIES, 1000000).
-define(MAX_CONFIG_CONCURRENCY, 1024).

-record(state, {
    bucket :: binary(),
    project :: binary(),
    credential :: {module(), term()},
    transport :: {module(), term()},
    prefix :: binary(),
    max_artifact_bytes :: pos_integer(),
    max_response_bytes :: pos_integer(),
    max_page_limit :: pos_integer(),
    legacy_list_limit :: pos_integer(),
    max_scan_entries :: pos_integer(),
    max_concurrency :: pos_integer(),
    max_reservation_attempts :: pos_integer(),
    call_timeout_ms :: pos_integer(),
    stream_limits :: map(),
    stream_sup :: pid(),
    operations = #{} :: map()
}).

-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) when is_map(Config) ->
    case validate_config(Config) of
        {ok, Prepared} -> gen_server:start_link(?MODULE, Prepared, []);
        {error, _} = Error -> Error
    end;
start_link(_Config) ->
    {error, invalid_config}.

-spec capabilities(pid()) -> {ok, map()} | {error, term()}.
capabilities(Handle) ->
    safe_call(Handle, capabilities, ?DEFAULT_CALL_TIMEOUT_MS).

-spec put(pid(), adk_artifact_service:scope(), binary(), binary(), map()) ->
    {ok, adk_artifact_service:artifact_meta()} | {error, term()}.
put(Handle, Scope, Name, Data, Options) ->
    put(Handle, Scope, Name, Data, Options, #{}).

-spec put(pid(), adk_artifact_service:scope(), binary(), binary(), map(),
          adk_artifact_service:call_options()) ->
    {ok, adk_artifact_service:artifact_meta()} | {error, term()}.
put(Handle, Scope, Name, Data, Options, CallOptions) ->
    timed_call(Handle,
               fun(Deadline) ->
                   {operation, {put, Scope, Name, Data, Options}, Deadline}
               end, CallOptions, ?DEFAULT_CALL_TIMEOUT_MS).

-spec get(pid(), adk_artifact_service:scope(), binary(),
          adk_artifact_service:selector()) ->
    {ok, adk_artifact_service:artifact()} | {error, term()}.
get(Handle, Scope, Name, Selector) ->
    get(Handle, Scope, Name, Selector, #{}).

-spec get(pid(), adk_artifact_service:scope(), binary(),
          adk_artifact_service:selector(),
          adk_artifact_service:call_options()) ->
    {ok, adk_artifact_service:artifact()} | {error, term()}.
get(Handle, Scope, Name, Selector, CallOptions) ->
    timed_call(Handle,
               fun(Deadline) ->
                   {operation, {get, Scope, Name, Selector}, Deadline}
               end, CallOptions, ?DEFAULT_CALL_TIMEOUT_MS).

-spec get_range(pid(), adk_artifact_service:scope(), binary(),
                adk_artifact_service:selector(),
                adk_artifact_service:byte_range(),
                adk_artifact_service:call_options()) ->
    {ok, adk_artifact_service:ranged_artifact()} | {error, term()}.
get_range(Handle, Scope, Name, Selector, Range, CallOptions) ->
    timed_call(Handle,
               fun(Deadline) ->
                   {operation, {get_range, Scope, Name, Selector, Range},
                    Deadline}
               end, CallOptions, ?DEFAULT_CALL_TIMEOUT_MS).

-spec list(pid(), adk_artifact_service:scope()) ->
    {ok, [adk_artifact_service:artifact_meta()]} | {error, term()}.
list(Handle, Scope) ->
    timed_call(Handle,
               fun(Deadline) -> {operation, {list, Scope}, Deadline} end,
               #{}, ?DEFAULT_CALL_TIMEOUT_MS).

-spec list_names(pid(), adk_artifact_service:scope(), map()) ->
    {ok, adk_artifact_service:name_page()} | {error, term()}.
list_names(Handle, Scope, Options) ->
    timed_call(Handle,
               fun(Deadline) ->
                   {operation, {list_names, Scope, Options}, Deadline}
               end, #{}, ?DEFAULT_CALL_TIMEOUT_MS).

-spec list_versions(pid(), adk_artifact_service:scope(), binary(), map()) ->
    {ok, adk_artifact_service:version_page()} | {error, term()}.
list_versions(Handle, Scope, Name, Options) ->
    timed_call(Handle,
               fun(Deadline) ->
                   {operation, {list_versions, Scope, Name, Options},
                    Deadline}
               end, #{}, ?DEFAULT_CALL_TIMEOUT_MS).

-spec delete(pid(), adk_artifact_service:scope(), binary(),
             adk_artifact_service:delete_selector()) -> ok | {error, term()}.
delete(Handle, Scope, Name, Selector) ->
    delete(Handle, Scope, Name, Selector, #{}).

-spec delete(pid(), adk_artifact_service:scope(), binary(),
             adk_artifact_service:delete_selector(),
             adk_artifact_service:call_options()) -> ok | {error, term()}.
delete(Handle, Scope, Name, Selector, CallOptions) ->
    timed_call(Handle,
               fun(Deadline) ->
                   {operation, {delete, Scope, Name, Selector}, Deadline}
               end, CallOptions, ?DEFAULT_CALL_TIMEOUT_MS).

-spec start_upload(pid(), adk_artifact_service:scope(), binary(), map(), map()) ->
    {ok, adk_artifact_stream:stream(), map()} | {error, term()}.
start_upload(Handle, Scope, Name, PutOptions, TransferOptions) ->
    case prepare_transfer_options(TransferOptions, self()) of
        {ok, Prepared} ->
            safe_call(Handle, {start_upload, Scope, Name, PutOptions, Prepared},
                      ?DEFAULT_CALL_TIMEOUT_MS);
        {error, _} = Error -> Error
    end.

-spec start_download(pid(), adk_artifact_service:scope(), binary(),
                     adk_artifact_service:selector(), map()) ->
    {ok, adk_artifact_stream:stream(), map()} | {error, term()}.
start_download(Handle, Scope, Name, Selector, TransferOptions) ->
    case prepare_transfer_options(TransferOptions, self()) of
        {ok, Prepared} ->
            start_download_lookup(Handle, Scope, Name, Selector, Prepared);
        {error, _} = Error -> Error
    end.

-spec stop(pid()) -> ok | {error, term()}.
stop(Handle) ->
    safe_call(Handle, stop, ?DEFAULT_CALL_TIMEOUT_MS).

init(Prepared) ->
    process_flag(message_queue_data, off_heap),
    case adk_artifact_stream_sup:start_link() of
        {ok, StreamSup} ->
            {ok, #state{
                bucket = maps:get(bucket, Prepared),
                project = maps:get(project, Prepared),
                credential = maps:get(credential, Prepared),
                transport = maps:get(transport, Prepared),
                prefix = maps:get(prefix, Prepared),
                max_artifact_bytes = maps:get(max_artifact_bytes, Prepared),
                max_response_bytes = maps:get(max_response_bytes, Prepared),
                max_page_limit = maps:get(max_page_limit, Prepared),
                legacy_list_limit = maps:get(legacy_list_limit, Prepared),
                max_scan_entries = maps:get(max_scan_entries, Prepared),
                max_concurrency = maps:get(max_concurrency, Prepared),
                max_reservation_attempts =
                    maps:get(max_reservation_attempts, Prepared),
                call_timeout_ms = maps:get(call_timeout_ms, Prepared),
                stream_limits = maps:get(stream_limits, Prepared),
                stream_sup = StreamSup
            }};
        {error, _} -> {stop, stream_supervisor_unavailable}
    end.

handle_call(capabilities, _From, State) ->
    {reply, {ok, capability_map(State)}, State};
handle_call({start_upload, Scope, Name, PutOptions, TransferOptions},
            _From, State) ->
    Limits = State#state.stream_limits,
    Reply = adk_artifact_stream_sup:start_upload(
              State#state.stream_sup, {?MODULE, self()}, Scope, Name,
              PutOptions, TransferOptions, Limits),
    {reply, Reply, State};
handle_call({start_download_ready, Artifact, TransferOptions}, _From, State) ->
    Reply = adk_artifact_stream_sup:start_download(
              State#state.stream_sup, Artifact, TransferOptions,
              State#state.stream_limits, #{}),
    {reply, Reply, State};
handle_call({operation, Request, Deadline}, From, State) ->
    start_operation(Request, Deadline, From, State);
handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({gcs_operation_result, OpRef, Pid, CompletedAt, Result}, State) ->
    complete_operation(OpRef, Pid, CompletedAt, Result, State);
handle_info({gcs_operation_deadline, OpRef}, State) ->
    timeout_operation(OpRef, State);
handle_info({'DOWN', Monitor, process, Pid, _Reason}, State) ->
    down_operation(Monitor, Pid, State);
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    maps:foreach(fun(_Ref, Op) -> cancel_operation(Op) end,
                 State#state.operations),
    exit(State#state.stream_sup, shutdown),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

format_status(Status) when is_map(Status) ->
    maps:map(
      fun(state, State = #state{transport = {Module, _Handle}}) ->
              State#state{credential = {redacted, redacted},
                          transport = {Module, redacted},
                          operations =
                              #{active => map_size(State#state.operations)}};
         (message, _Message) -> redacted;
         (log, _Log) -> [];
         (reason, _Reason) -> redacted;
         (_Key, Value) -> Value
      end, Status);
format_status(Status) -> Status.

start_download_lookup(Handle, Scope, Name, Selector, Options) ->
    Timeout = maps:get(timeout_ms, Options),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Lookup = case maps:find(range, Options) of
        {ok, Range} ->
            get_range(Handle, Scope, Name, Selector, Range,
                      #{timeout_ms => erlang:max(1, remaining(Deadline))});
        error ->
            get(Handle, Scope, Name, Selector,
                #{timeout_ms => erlang:max(1, remaining(Deadline))})
    end,
    case Lookup of
        {ok, Artifact} ->
            case remaining(Deadline) of
                0 -> {error, timeout};
                Left ->
                    StreamOptions = Options#{timeout_ms => Left},
                    safe_call(Handle,
                              {start_download_ready, Artifact, StreamOptions},
                              Left)
            end;
        {error, _} = Error -> Error
    end.

start_operation(_Request, Deadline, _From, State)
  when not is_integer(Deadline) ->
    {reply, {error, invalid_deadline}, State};
start_operation(Request, Deadline, From, State) ->
    case {remaining(Deadline),
          map_size(State#state.operations) < State#state.max_concurrency} of
        {0, _} -> {reply, {error, timeout}, State};
        {_, false} -> {reply, {error, overloaded}, State};
        {Left, true} ->
            Server = self(),
            OpRef = make_ref(),
            Config = operation_config(State),
            Fun = fun() ->
                Result = try execute(Request, Deadline, Config)
                         catch _:_ -> {error, unavailable}
                         end,
                CompletedAt = erlang:monotonic_time(millisecond),
                Server ! {gcs_operation_result, OpRef, self(), CompletedAt,
                          Result}
            end,
            Options = [monitor, {message_queue_data, off_heap},
                       {max_heap_size,
                        #{size => ?OPERATION_MAX_HEAP_WORDS, kill => true,
                          error_logger => false,
                          include_shared_binaries => true}}],
            try erlang:spawn_opt(Fun, Options) of
                {Pid, Monitor} ->
                    {Caller, _Tag} = From,
                    CallerMonitor = erlang:monitor(process, Caller),
                    Timer = erlang:send_after(
                              Left, self(), {gcs_operation_deadline, OpRef}),
                    Op = #{pid => Pid, monitor => Monitor,
                           caller => Caller, caller_monitor => CallerMonitor,
                           timer => Timer, from => From, deadline => Deadline},
                    Operations = (State#state.operations)#{OpRef => Op},
                    {noreply, State#state{operations = Operations}}
            catch
                _:_ -> {reply, {error, unavailable}, State}
            end
    end.

complete_operation(OpRef, Pid, CompletedAt, Result, State) ->
    case maps:find(OpRef, State#state.operations) of
        {ok, #{pid := Pid, deadline := Deadline, from := From} = Op} ->
            finish_operation_monitors(Op),
            Reply = case CompletedAt =< Deadline of
                true -> Result;
                false -> {error, timeout}
            end,
            gen_server:reply(From, Reply),
            Operations = maps:remove(OpRef, State#state.operations),
            {noreply, State#state{operations = Operations}};
        _ -> {noreply, State}
    end.

timeout_operation(OpRef, State) ->
    case maps:take(OpRef, State#state.operations) of
        {Op, Operations} ->
            cancel_operation(Op),
            gen_server:reply(maps:get(from, Op), {error, timeout}),
            {noreply, State#state{operations = Operations}};
        error -> {noreply, State}
    end.

down_operation(Monitor, Pid, State) ->
    case find_operation(Monitor, Pid, State#state.operations) of
        {worker, OpRef, Op} ->
            finish_operation_monitors(Op),
            gen_server:reply(maps:get(from, Op), {error, unavailable}),
            {noreply, State#state{
                        operations = maps:remove(OpRef,
                                                 State#state.operations)}};
        {caller, OpRef, Op} ->
            cancel_operation(Op),
            {noreply, State#state{
                        operations = maps:remove(OpRef,
                                                 State#state.operations)}};
        not_found -> {noreply, State}
    end.

find_operation(Monitor, Pid, Operations) ->
    maps:fold(
      fun(OpRef, Op, not_found) ->
              case {maps:get(monitor, Op), maps:get(pid, Op),
                    maps:get(caller_monitor, Op), maps:get(caller, Op)} of
                  {Monitor, Pid, _, _} -> {worker, OpRef, Op};
                  {_, _, Monitor, Pid} -> {caller, OpRef, Op};
                  _ -> not_found
              end;
         (_OpRef, _Op, Found) -> Found
      end, not_found, Operations).

finish_operation_monitors(Op) ->
    _ = erlang:cancel_timer(maps:get(timer, Op)),
    _ = erlang:demonitor(maps:get(monitor, Op), [flush]),
    _ = erlang:demonitor(maps:get(caller_monitor, Op), [flush]),
    ok.

cancel_operation(Op) ->
    exit(maps:get(pid, Op), kill),
    finish_operation_monitors(Op).

operation_config(State) ->
    #{bucket => State#state.bucket,
      project => State#state.project,
      credential => State#state.credential,
      transport => State#state.transport,
      prefix => State#state.prefix,
      max_artifact_bytes => State#state.max_artifact_bytes,
      max_response_bytes => State#state.max_response_bytes,
      max_page_limit => State#state.max_page_limit,
      legacy_list_limit => State#state.legacy_list_limit,
      max_scan_entries => State#state.max_scan_entries,
      max_reservation_attempts => State#state.max_reservation_attempts}.

execute({put, Scope, Name, Data, Options}, Deadline, Config) ->
    do_put(Scope, Name, Data, Options, Deadline, Config);
execute({get, Scope, Name, Selector}, Deadline, Config) ->
    do_get(Scope, Name, Selector, Deadline, Config);
execute({get_range, Scope, Name, Selector, Range}, Deadline, Config) ->
    do_get_range(Scope, Name, Selector, Range, Deadline, Config);
execute({list, Scope}, Deadline, Config) ->
    do_list(Scope, Deadline, Config);
execute({list_names, Scope, Options}, Deadline, Config) ->
    do_list_names(Scope, Options, Deadline, Config);
execute({list_versions, Scope, Name, Options}, Deadline, Config) ->
    do_list_versions(Scope, Name, Options, Deadline, Config);
execute({delete, Scope, Name, Selector}, Deadline, Config) ->
    do_delete(Scope, Name, Selector, Deadline, Config);
execute(_Request, _Deadline, _Config) ->
    {error, unsupported_request}.

do_put(Scope, Name, Data, Options, Deadline, Config) ->
    case adk_artifact_core:validate_put(Scope, Name, Data, Options) of
        {ok, MimeType, UserMetadata} ->
            case byte_size(Data) =< maps:get(max_artifact_bytes, Config) of
                false -> {error, artifact_too_large};
                true ->
                    put_validated(Scope, Name, Data, MimeType, UserMetadata,
                                  Deadline, Config)
            end;
        {error, _} = Error -> Error
    end.

put_validated(Scope, Name, Data, MimeType, UserMetadata, Deadline, Config) ->
    Root = name_root(Config, Scope, Name),
    case allocate_version(Root, Deadline, Config) of
        {ok, Version} ->
            Metadata = adk_artifact_core:artifact_metadata(
                         Scope, Name, Version, Data, MimeType, UserMetadata),
            DataObject = version_object(Root, Version, <<".data">>),
            MetaObject = version_object(Root, Version, <<".meta">>),
            Context = context(Config, Deadline,
                              maps:get(max_response_bytes, Config)),
            case transport_put(Config, DataObject, Data, Context) of
                ok ->
                    Encoded = term_to_binary(Metadata, [deterministic]),
                    case byte_size(Encoded) =< ?MAX_METADATA_BYTES of
                        false -> {error, invalid_metadata};
                        true ->
                            case transport_put(Config, MetaObject, Encoded,
                                               Context) of
                                ok -> {ok, Metadata};
                                {error, exists} -> {error, corrupt_artifact};
                                {error, _} = Error -> Error
                            end
                    end;
                {error, exists} -> {error, corrupt_artifact};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

allocate_version(Root, Deadline, Config) ->
    case list_all(Root, Deadline, Config) of
        {ok, Objects} ->
            Max = lists:foldl(fun(Object, Acc) ->
                                      erlang:max(Acc,
                                                 any_object_version(Object,
                                                                    Root))
                              end, 0, Objects),
            reserve_version(Root, Max + 1, 0, Deadline, Config);
        {error, _} = Error -> Error
    end.

reserve_version(Root, Version, Attempts, Deadline, Config) ->
    case Attempts >= maps:get(max_reservation_attempts, Config) of
        true -> {error, version_allocation_exhausted};
        false ->
            Object = version_object(Root, Version, <<".reserve">>),
            Context = context(Config, Deadline, ?MAX_METADATA_BYTES),
            case transport_put(Config, Object, <<>>, Context) of
                ok -> {ok, Version};
                {error, exists} ->
                    reserve_version(Root, Version + 1, Attempts + 1,
                                    Deadline, Config);
                {error, _} = Error -> Error
            end
    end.

do_get(Scope, Name, Selector, Deadline, Config) ->
    case adk_artifact_core:validate_lookup(Scope, Name, Selector) of
        ok ->
            case resolve_metadata(Scope, Name, Selector, Deadline, Config) of
                {ok, Metadata} -> load_data(Metadata, Deadline, Config);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

do_get_range(Scope, Name, Selector, Range, Deadline, Config) ->
    case adk_artifact_core:validate_lookup(Scope, Name, Selector) of
        ok ->
            case resolve_metadata(Scope, Name, Selector, Deadline, Config) of
                {ok, Metadata} ->
                    range_data(Metadata, Range, Deadline, Config);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

load_data(Metadata, Deadline, Config) ->
    Scope = maps:get(scope, Metadata),
    Name = maps:get(name, Metadata),
    Version = maps:get(version, Metadata),
    Object = version_object(name_root(Config, Scope, Name), Version,
                            <<".data">>),
    Limit = erlang:max(1, maps:get(size, Metadata)),
    Context = context(Config, Deadline, Limit),
    case transport_get(Config, Object, Context) of
        {ok, Data} -> adk_artifact_core:validate_loaded_data(Metadata, Data);
        {error, not_found} -> {error, corrupt_artifact};
        {error, _} = Error -> Error
    end.

range_data(Metadata, Range, Deadline, Config) ->
    Size = maps:get(size, Metadata),
    case validate_range(Range, Size, maps:get(max_artifact_bytes, Config)) of
        {ok, Offset, Length} ->
            Object = version_object(
                       name_root(Config, maps:get(scope, Metadata),
                                 maps:get(name, Metadata)),
                       maps:get(version, Metadata), <<".data">>),
            Context = context(Config, Deadline, Length),
            case transport_get_range(Config, Object, Offset, Length,
                                     Context) of
                {ok, Data} when byte_size(Data) =:= Length ->
                    {ok, Metadata#{data => Data,
                                   range => #{offset => Offset,
                                              length => Length,
                                              total_size => Size}}};
                {ok, _Data} -> {error, corrupt_artifact};
                {error, not_found} -> {error, corrupt_artifact};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

do_list(Scope, Deadline, Config) ->
    case load_scope_metadata(Scope, Deadline, Config) of
        {ok, Items} ->
            case length(Items) =< maps:get(legacy_list_limit, Config) of
                true -> {ok, Items};
                false -> {error, result_limit_exceeded}
            end;
        {error, _} = Error -> Error
    end.

do_list_names(Scope, Options, Deadline, Config) ->
    Validation = adk_artifact_core:validate_page_options(
                   Options, name, maps:get(max_page_limit, Config)),
    case {adk_artifact_core:validate_scope(Scope), Validation} of
        {ok, {ok, Limit, Cursor}} ->
            case load_scope_metadata(Scope, Deadline, Config) of
                {ok, Metadata} ->
                    Names = lists:usort([maps:get(name, Item)
                                         || Item <- Metadata]),
                    Page = page_names(Names, Cursor, Limit),
                    {ok, Page#{scope => Scope}};
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

do_list_versions(Scope, Name, Options, Deadline, Config) ->
    Validation = adk_artifact_core:validate_page_options(
                   Options, version, maps:get(max_page_limit, Config)),
    case {adk_artifact_core:validate_lookup(Scope, Name, latest), Validation} of
        {ok, {ok, Limit, Cursor}} ->
            case load_versions(Scope, Name, Deadline, Config) of
                {ok, Items} -> {ok, page_versions(Items, Cursor, Limit)};
                {error, _} = Error -> Error
            end;
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

do_delete(Scope, Name, Selector, Deadline, Config) ->
    case adk_artifact_core:validate_delete(Scope, Name, Selector) of
        ok ->
            case delete_versions(Scope, Name, Selector, Deadline, Config) of
                {ok, []} -> {error, not_found};
                {ok, Items} -> delete_metadata_items(Items, Deadline, Config);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

delete_versions(Scope, Name, all, Deadline, Config) ->
    load_versions(Scope, Name, Deadline, Config);
delete_versions(Scope, Name, Selector, Deadline, Config) ->
    case resolve_metadata(Scope, Name, Selector, Deadline, Config) of
        {ok, Metadata} -> {ok, [Metadata]};
        {error, _} = Error -> Error
    end.

delete_metadata_items([], _Deadline, _Config) -> ok;
delete_metadata_items([Metadata | Rest], Deadline, Config) ->
    Root = name_root(Config, maps:get(scope, Metadata),
                     maps:get(name, Metadata)),
    Version = maps:get(version, Metadata),
    MetaObject = version_object(Root, Version, <<".meta">>),
    DataObject = version_object(Root, Version, <<".data">>),
    Context = context(Config, Deadline, ?MAX_METADATA_BYTES),
    case transport_delete(Config, MetaObject, Context) of
        ok ->
            case transport_delete(Config, DataObject, Context) of
                ok -> delete_metadata_items(Rest, Deadline, Config);
                {error, not_found} -> {error, corrupt_artifact};
                {error, _} = Error -> Error
            end;
        {error, not_found} -> {error, not_found};
        {error, _} = Error -> Error
    end.

resolve_metadata(Scope, Name, latest, Deadline, Config) ->
    case load_versions(Scope, Name, Deadline, Config) of
        {ok, []} -> {error, not_found};
        {ok, Items} -> {ok, lists:last(Items)};
        {error, _} = Error -> Error
    end;
resolve_metadata(Scope, Name, Version, Deadline, Config) ->
    Root = name_root(Config, Scope, Name),
    Object = version_object(Root, Version, <<".meta">>),
    load_metadata_object(Object, {Scope, Name, Version}, Deadline, Config).

load_versions(Scope, Name, Deadline, Config) ->
    Root = name_root(Config, Scope, Name),
    case list_all(Root, Deadline, Config) of
        {ok, Objects} ->
            MetaObjects = [Object || Object <- Objects,
                                     metadata_version(Object, Root) =/= 0],
            load_metadata_objects(MetaObjects, {Scope, Name}, Deadline,
                                  Config, []);
        {error, _} = Error -> Error
    end.

load_scope_metadata(Scope, Deadline, Config) ->
    case adk_artifact_core:validate_scope(Scope) of
        ok ->
            Prefix = scope_root(Config, Scope),
            case list_all(Prefix, Deadline, Config) of
                {ok, Objects} ->
                    MetaObjects = [Object || Object <- Objects,
                                             has_suffix(Object, <<".meta">>)],
                    load_scope_objects(MetaObjects, Scope, Deadline, Config,
                                       []);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

load_metadata_objects([], _Identity, _Deadline, _Config, Acc) ->
    {ok, lists:sort(fun compare_version/2, Acc)};
load_metadata_objects([Object | Rest], {Scope, Name} = Identity,
                      Deadline, Config, Acc) ->
    Version = metadata_version(Object, name_root(Config, Scope, Name)),
    case load_metadata_object(Object, {Scope, Name, Version}, Deadline,
                              Config) of
        {ok, Metadata} ->
            load_metadata_objects(Rest, Identity, Deadline, Config,
                                  [Metadata | Acc]);
        {error, _} = Error -> Error
    end.

load_scope_objects([], _Scope, _Deadline, _Config, Acc) ->
    {ok, lists:sort(fun compare_identity/2, Acc)};
load_scope_objects([Object | Rest], Scope, Deadline, Config, Acc) ->
    Context = context(Config, Deadline, ?MAX_METADATA_BYTES),
    case transport_get(Config, Object, Context) of
        {ok, Binary} ->
            case decode_untrusted_metadata(Binary) of
                {ok, Metadata} ->
                    Name = maps:get(name, Metadata, invalid),
                    Version = maps:get(version, Metadata, invalid),
                    Expected = version_object(name_root(Config, Scope, Name),
                                              Version, <<".meta">>),
                    case Object =:= Expected andalso
                         adk_artifact_core:validate_loaded_metadata(
                           Metadata, Scope, Name, Version) =:= {ok, Metadata} of
                        true ->
                            load_scope_objects(Rest, Scope, Deadline, Config,
                                               [Metadata | Acc]);
                        false -> {error, corrupt_artifact}
                    end;
                {error, _} = Error -> Error
            end;
        {error, not_found} -> {error, corrupt_artifact};
        {error, _} = Error -> Error
    end.

load_metadata_object(Object, {Scope, Name, Version}, Deadline, Config) ->
    Context = context(Config, Deadline, ?MAX_METADATA_BYTES),
    case transport_get(Config, Object, Context) of
        {ok, Binary} ->
            case decode_untrusted_metadata(Binary) of
                {ok, Metadata} ->
                    adk_artifact_core:validate_loaded_metadata(
                      Metadata, Scope, Name, Version);
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

decode_untrusted_metadata(Binary)
  when is_binary(Binary), byte_size(Binary) =< ?MAX_METADATA_BYTES ->
    try binary_to_term(Binary, [safe]) of
        Metadata when is_map(Metadata) -> {ok, Metadata};
        _ -> {error, corrupt_artifact}
    catch
        _:_ -> {error, corrupt_artifact}
    end;
decode_untrusted_metadata(_Binary) ->
    {error, corrupt_artifact}.

list_all(Prefix, Deadline, Config) ->
    list_all(Prefix, undefined, Deadline, Config,
             maps:get(max_scan_entries, Config), [], #{}).

list_all(_Prefix, _Cursor, _Deadline, _Config, 0, _Acc, _Seen) ->
    {error, scan_limit_exceeded};
list_all(Prefix, Cursor, Deadline, Config, Remaining, Acc, Seen) ->
    Limit = erlang:min(1000, Remaining),
    Context = context(Config, Deadline,
                      maps:get(max_response_bytes, Config)),
    case transport_list(Config, Prefix, Cursor, Limit, Context) of
        {ok, #{items := Items, next_cursor := Next}}
          when is_list(Items), length(Items) =< Limit ->
            case valid_object_items(Items, Prefix) of
                false -> {error, invalid_storage_response};
                true ->
                    Left = Remaining - length(Items),
                    NewAcc = lists:reverse(Items, Acc),
                    case Next of
                        undefined -> {ok, lists:reverse(NewAcc)};
                        _ when Left =:= 0 -> {error, scan_limit_exceeded};
                        _ ->
                            case maps:is_key(Next, Seen) of
                                true -> {error, invalid_storage_response};
                                false ->
                                    list_all(Prefix, Next, Deadline, Config,
                                             Left, NewAcc, Seen#{Next => true})
                            end
                    end
            end;
        {ok, _Invalid} -> {error, invalid_storage_response};
        {error, _} = Error -> Error
    end.

transport_put(Config, Object, Data, Context) ->
    {Module, Handle} = maps:get(transport, Config),
    try Module:put_if_absent(Handle, Object, Data, Context) of
        ok -> ok;
        {error, exists} -> {error, exists};
        {error, timeout} -> {error, timeout};
        {error, overloaded} -> {error, overloaded};
        {error, credential_unavailable} -> {error, credential_unavailable};
        {error, forbidden} -> {error, forbidden};
        {error, _} -> {error, unavailable};
        _ -> {error, unavailable}
    catch _:_ -> {error, unavailable}
    end.

transport_get(Config, Object, Context) ->
    {Module, Handle} = maps:get(transport, Config),
    try Module:get(Handle, Object, Context) of
        {ok, Data} when is_binary(Data) ->
            case byte_size(Data) =< maps:get(max_response_bytes, Context) of
                true -> {ok, Data};
                false -> {error, response_too_large}
            end;
        {error, not_found} -> {error, not_found};
        {error, timeout} -> {error, timeout};
        {error, credential_unavailable} -> {error, credential_unavailable};
        {error, forbidden} -> {error, forbidden};
        {error, _} -> {error, unavailable};
        _ -> {error, unavailable}
    catch _:_ -> {error, unavailable}
    end.

transport_get_range(Config, Object, Offset, Length, Context) ->
    {Module, Handle} = maps:get(transport, Config),
    try Module:get_range(Handle, Object, Offset, Length, Context) of
        {ok, Data} when is_binary(Data), byte_size(Data) =< Length ->
            {ok, Data};
        {ok, _Data} -> {error, response_too_large};
        {error, not_found} -> {error, not_found};
        {error, timeout} -> {error, timeout};
        {error, credential_unavailable} -> {error, credential_unavailable};
        {error, forbidden} -> {error, forbidden};
        {error, _} -> {error, unavailable};
        _ -> {error, unavailable}
    catch _:_ -> {error, unavailable}
    end.

transport_list(Config, Prefix, Cursor, Limit, Context) ->
    {Module, Handle} = maps:get(transport, Config),
    try Module:list(Handle, Prefix, Cursor, Limit, Context) of
        {ok, Page} when is_map(Page) -> {ok, Page};
        {error, timeout} -> {error, timeout};
        {error, credential_unavailable} -> {error, credential_unavailable};
        {error, forbidden} -> {error, forbidden};
        {error, _} -> {error, unavailable};
        _ -> {error, unavailable}
    catch _:_ -> {error, unavailable}
    end.

transport_delete(Config, Object, Context) ->
    {Module, Handle} = maps:get(transport, Config),
    try Module:delete(Handle, Object, Context) of
        ok -> ok;
        {error, not_found} -> {error, not_found};
        {error, timeout} -> {error, timeout};
        {error, credential_unavailable} -> {error, credential_unavailable};
        {error, forbidden} -> {error, forbidden};
        {error, _} -> {error, unavailable};
        _ -> {error, unavailable}
    catch _:_ -> {error, unavailable}
    end.

context(Config, Deadline, ResponseLimit) ->
    #{bucket => maps:get(bucket, Config),
      project => maps:get(project, Config),
      credential => maps:get(credential, Config),
      deadline => Deadline,
      max_response_bytes => erlang:max(1, ResponseLimit)}.

scope_root(Config, Scope) ->
    Prefix = maps:get(prefix, Config),
    <<Prefix/binary, "/s/", (hash_term(Scope))/binary, "/n/">>.

name_root(Config, Scope, Name) ->
    ScopeRoot = scope_root(Config, Scope),
    <<ScopeRoot/binary, (hash_term(Name))/binary, "/">>.

version_object(Root, Version, Suffix) ->
    Digits = pad_version(Version),
    <<Root/binary, "v-", Digits/binary, Suffix/binary>>.

pad_version(Version) when is_integer(Version), Version > 0 ->
    Binary = integer_to_binary(Version),
    Padding = erlang:max(0, 20 - byte_size(Binary)),
    <<(binary:copy(<<"0">>, Padding))/binary, Binary/binary>>.

hash_term(Term) ->
    binary:encode_hex(
      crypto:hash(sha256, term_to_binary(Term, [deterministic])), lowercase).

any_object_version(Object, Root) ->
    lists:max([metadata_version(Object, Root),
               suffix_version(Object, Root, <<".data">>),
               suffix_version(Object, Root, <<".reserve">>)]).

metadata_version(Object, Root) ->
    suffix_version(Object, Root, <<".meta">>).

suffix_version(Object, Root, Suffix) ->
    Prefix = <<Root/binary, "v-">>,
    PrefixSize = byte_size(Prefix),
    SuffixSize = byte_size(Suffix),
    case byte_size(Object) =:= PrefixSize + 20 + SuffixSize andalso
         binary:part(Object, 0, PrefixSize) =:= Prefix andalso
         binary:part(Object, PrefixSize + 20, SuffixSize) =:= Suffix of
        true ->
            Digits = binary:part(Object, PrefixSize, 20),
            case all_digits(Digits) of
                true ->
                    try binary_to_integer(Digits) of
                        Version when Version > 0 -> Version;
                        _ -> 0
                    catch _:_ -> 0
                    end;
                false -> 0
            end;
        false -> 0
    end.

all_digits(Binary) ->
    lists:all(fun(Byte) -> Byte >= $0 andalso Byte =< $9 end,
              binary_to_list(Binary)).

has_suffix(Binary, Suffix) when byte_size(Binary) >= byte_size(Suffix) ->
    binary:part(Binary, byte_size(Binary) - byte_size(Suffix),
                byte_size(Suffix)) =:= Suffix;
has_suffix(_Binary, _Suffix) -> false.

valid_object_items(Items, Prefix) ->
    lists:all(
      fun(Item) ->
          is_binary(Item) andalso byte_size(Item) > byte_size(Prefix) andalso
          byte_size(Item) =< ?MAX_OBJECT_NAME_BYTES andalso
          binary:part(Item, 0, byte_size(Prefix)) =:= Prefix
      end, Items).

validate_range(Range, Size, Max)
  when is_map(Range), is_integer(Size), Size >= 0 ->
    Unknown = maps:without([offset, length], Range),
    Offset = maps:get(offset, Range, invalid),
    Length = maps:get(length, Range, invalid),
    case {map_size(Unknown), is_integer(Offset), is_integer(Length)} of
        {0, true, true}
          when Offset >= 0, Length > 0, Offset =< Max, Length =< Max,
               Offset < Size, Offset + Length =< Size ->
            {ok, Offset, Length};
        {UnknownSize, _, _} when UnknownSize > 0 ->
            {error, {unknown_range_options,
                     lists:sort(maps:keys(Unknown))}};
        _ -> {error, invalid_range}
    end;
validate_range(_Range, _Size, _Max) ->
    {error, invalid_range}.

page_names(Names, undefined, Limit) -> page_names_after(Names, Limit);
page_names(Names, Cursor, Limit) ->
    page_names_after(lists:dropwhile(fun(Name) -> Name =< Cursor end, Names),
                     Limit).

page_names_after(Names, Limit) ->
    {Page, More} = take_page(Names, Limit),
    Next = case More of true -> lists:last(Page); false -> undefined end,
    #{items => Page, next_cursor => Next}.

page_versions(Items, undefined, Limit) -> page_versions_after(Items, Limit);
page_versions(Items, Cursor, Limit) ->
    page_versions_after(
      lists:dropwhile(fun(Item) -> maps:get(version, Item) =< Cursor end,
                      Items), Limit).

page_versions_after(Items, Limit) ->
    {Page, More} = take_page(Items, Limit),
    Next = case More of
        true -> maps:get(version, lists:last(Page));
        false -> undefined
    end,
    #{items => Page, next_cursor => Next}.

take_page(Items, Limit) ->
    Candidates = lists:sublist(Items, Limit + 1),
    case length(Candidates) > Limit of
        true -> {lists:sublist(Candidates, Limit), true};
        false -> {Candidates, false}
    end.

compare_version(A, B) -> maps:get(version, A) < maps:get(version, B).

compare_identity(A, B) ->
    {maps:get(name, A), maps:get(version, A)} <
        {maps:get(name, B), maps:get(version, B)}.

capability_map(State) ->
    #{api_version => 2,
      immutable_versions => true,
      scopes => [app, user, session],
      pagination => #{max_page_limit => State#state.max_page_limit,
                      legacy_list_limit => State#state.legacy_list_limit},
      deadlines => true,
      cancellation => owner_and_deadline,
      range_reads => true,
      persistence => durable_object_store,
      storage => gcs,
      publication => create_only_manifest,
      transfer => #{protocol => credit_ack,
                    upload => true,
                    download => true,
                    explicit_ack => true,
                    max_chunk_bytes =>
                        maps:get(chunk_bytes, State#state.stream_limits),
                    max_credit_messages =>
                        maps:get(max_credit_messages,
                                 State#state.stream_limits)},
      quotas => #{max_artifact_bytes => State#state.max_artifact_bytes},
      validation_limits => adk_artifact_core:limits()}.

validate_config(Config) ->
    Keys = [bucket, project, credential, transport, prefix,
            max_artifact_bytes, max_response_bytes, max_page_limit,
            legacy_list_limit, max_scan_entries, max_concurrency,
            max_reservation_attempts, call_timeout_ms, stream],
    Unknown = maps:without(Keys, Config),
    Bucket = maps:get(bucket, Config, invalid),
    Project = maps:get(project, Config, invalid),
    Credential = maps:get(credential, Config, invalid),
    Transport = maps:get(transport, Config,
                         {adk_artifact_gcs_http_transport, undefined}),
    Prefix = maps:get(prefix, Config, <<"adk-artifacts/v1">>),
    MaxArtifact = maps:get(max_artifact_bytes, Config,
                           ?DEFAULT_MAX_ARTIFACT_BYTES),
    Prepared = #{bucket => Bucket, project => Project,
                 credential => Credential, transport => Transport,
                 prefix => Prefix, max_artifact_bytes => MaxArtifact,
                 max_response_bytes =>
                     maps:get(max_response_bytes, Config,
                              erlang:max(MaxArtifact, 4 * 1024 * 1024)),
                 max_page_limit => maps:get(max_page_limit, Config,
                                             ?DEFAULT_MAX_PAGE_LIMIT),
                 legacy_list_limit => maps:get(legacy_list_limit, Config,
                                                ?DEFAULT_LEGACY_LIST_LIMIT),
                 max_scan_entries => maps:get(max_scan_entries, Config,
                                              ?DEFAULT_MAX_SCAN_ENTRIES),
                 max_concurrency => maps:get(max_concurrency, Config,
                                             ?DEFAULT_MAX_CONCURRENCY),
                 max_reservation_attempts =>
                     maps:get(max_reservation_attempts, Config,
                              ?DEFAULT_MAX_RESERVATION_ATTEMPTS),
                 call_timeout_ms => maps:get(call_timeout_ms, Config,
                                             ?DEFAULT_CALL_TIMEOUT_MS)},
    case {map_size(Unknown), valid_bucket(Bucket), valid_project(Project),
          adk_artifact_gcs_credential:validate_handle(Credential),
          valid_transport(Transport), valid_prefix(Prefix),
          valid_limits(Prepared),
          validate_stream_config(maps:get(stream, Config, #{}),
                                 MaxArtifact)} of
        {Size, _, _, _, _, _, _, _} when Size > 0 ->
            {error, {unknown_config, lists:sort(maps:keys(Unknown))}};
        {_, false, _, _, _, _, _, _} -> {error, invalid_bucket};
        {_, _, false, _, _, _, _, _} -> {error, invalid_project};
        {_, _, _, {error, _}, _, _, _, _} ->
            {error, invalid_credential_handle};
        {_, _, _, _, false, _, _, _} -> {error, invalid_transport};
        {_, _, _, _, _, false, _, _} -> {error, invalid_prefix};
        {_, _, _, _, _, _, false, _} -> {error, invalid_config_limit};
        {0, true, true, ok, true, true, true, {ok, StreamLimits}} ->
            {ok, Prepared#{stream_limits => StreamLimits}};
        {_, _, _, _, _, _, _, {error, _} = Error} -> Error
    end.

valid_limits(Prepared) ->
    Values = [maps:get(max_artifact_bytes, Prepared),
              maps:get(max_response_bytes, Prepared),
              maps:get(max_page_limit, Prepared),
              maps:get(legacy_list_limit, Prepared),
              maps:get(max_scan_entries, Prepared),
              maps:get(max_concurrency, Prepared),
              maps:get(max_reservation_attempts, Prepared),
              maps:get(call_timeout_ms, Prepared)],
    lists:all(fun(Value) -> is_integer(Value) andalso Value > 0 end, Values)
        andalso maps:get(max_artifact_bytes, Prepared) =<
                    ?MAX_CONFIG_ARTIFACT_BYTES
        andalso maps:get(max_response_bytes, Prepared) =<
                    ?MAX_CONFIG_ARTIFACT_BYTES
        andalso maps:get(max_page_limit, Prepared) =< ?MAX_CONFIG_PAGE_LIMIT
        andalso maps:get(max_scan_entries, Prepared) =<
                    ?MAX_CONFIG_SCAN_ENTRIES
        andalso maps:get(max_concurrency, Prepared) =<
                    ?MAX_CONFIG_CONCURRENCY
        andalso maps:get(max_reservation_attempts, Prepared) =<
                    ?MAX_CONFIG_SCAN_ENTRIES
        andalso maps:get(max_response_bytes, Prepared) >=
                    maps:get(max_artifact_bytes, Prepared)
        andalso maps:get(max_page_limit, Prepared) =<
                    maps:get(max_scan_entries, Prepared)
        andalso maps:get(call_timeout_ms, Prepared) =< 300000.

validate_stream_config(Stream, MaxArtifact) when is_map(Stream) ->
    Unknown = maps:without([chunk_bytes, max_credit_messages,
                            max_credit_bytes, timeout_ms], Stream),
    Chunk = maps:get(chunk_bytes, Stream, ?DEFAULT_STREAM_CHUNK_BYTES),
    Messages = maps:get(max_credit_messages, Stream,
                        ?DEFAULT_STREAM_CREDIT_MESSAGES),
    CreditBytes = maps:get(max_credit_bytes, Stream, Chunk * Messages),
    Timeout = maps:get(timeout_ms, Stream, ?DEFAULT_STREAM_TIMEOUT_MS),
    case {map_size(Unknown), valid_positive(Chunk),
          valid_positive(Messages), valid_positive(CreditBytes),
          valid_positive(Timeout), Chunk =< MaxArtifact,
          Chunk =< CreditBytes, CreditBytes =< MaxArtifact,
          Messages =< 1024, Timeout =< 300000} of
        {0, true, true, true, true, true, true, true, true, true} ->
            {ok, #{chunk_bytes => Chunk,
                   max_credit_messages => Messages,
                   max_credit_bytes => CreditBytes,
                   timeout_ms => Timeout,
                   max_bytes => MaxArtifact}};
        {Size, _, _, _, _, _, _, _, _, _} when Size > 0 ->
            {error, {unknown_stream_config,
                     lists:sort(maps:keys(Unknown))}};
        _ -> {error, invalid_stream_config}
    end;
validate_stream_config(_Stream, _MaxArtifact) ->
    {error, invalid_stream_config}.

prepare_transfer_options(Options, DefaultOwner) when is_map(Options) ->
    Allowed = [owner, timeout_ms, chunk_bytes, max_bytes, range],
    Unknown = maps:without(Allowed, Options),
    Owner = maps:get(owner, Options, DefaultOwner),
    Timeout = maps:get(timeout_ms, Options, ?DEFAULT_STREAM_TIMEOUT_MS),
    case {map_size(Unknown), is_pid(Owner), valid_positive(Timeout),
          Timeout =< 300000} of
        {0, true, true, true} ->
            {ok, Options#{owner => Owner, timeout_ms => Timeout}};
        {Size, _, _, _} when Size > 0 ->
            {error, {unknown_transfer_options,
                     lists:sort(maps:keys(Unknown))}};
        _ -> {error, invalid_transfer_options}
    end;
prepare_transfer_options(_Options, _Owner) ->
    {error, invalid_transfer_options}.

valid_transport({Module, _Handle}) when is_atom(Module) ->
    case code:ensure_loaded(Module) of
        {module, Module} ->
            lists:all(fun({Function, Arity}) ->
                              erlang:function_exported(Module, Function, Arity)
                      end,
                      [{put_if_absent, 4}, {get, 3}, {get_range, 5},
                       {list, 5}, {delete, 3}]);
        _ -> false
    end;
valid_transport(_Transport) -> false.

valid_bucket(Bucket)
  when is_binary(Bucket), byte_size(Bucket) >= 3, byte_size(Bucket) =< 63 ->
    Bytes = binary_to_list(Bucket),
    is_lower_alnum(hd(Bytes)) andalso is_lower_alnum(lists:last(Bytes)) andalso
    lists:all(fun(Byte) -> is_lower_alnum(Byte) orelse Byte =:= $- orelse
                              Byte =:= $.
              end, Bytes) andalso
    binary:match(Bucket, <<"..">>) =:= nomatch;
valid_bucket(_Bucket) -> false.

valid_project(Project)
  when is_binary(Project), byte_size(Project) > 0,
       byte_size(Project) =< 128 ->
    lists:all(fun(Byte) -> is_ascii_alnum(Byte) orelse Byte =:= $- orelse
                              Byte =:= $_ orelse Byte =:= $. orelse
                              Byte =:= $:
              end, binary_to_list(Project));
valid_project(_Project) -> false.

valid_prefix(Prefix)
  when is_binary(Prefix), byte_size(Prefix) > 0,
       byte_size(Prefix) =< 256 ->
    binary:first(Prefix) =/= $/ andalso binary:last(Prefix) =/= $/ andalso
    not has_control(Prefix) andalso
    lists:all(fun(<<>>) -> false;
                 (<<".">>) -> false;
                 (<<"..">>) -> false;
                 (_Part) -> true
              end, binary:split(Prefix, <<"/">>, [global]));
valid_prefix(_Prefix) -> false.

is_lower_alnum(Byte) ->
    (Byte >= $a andalso Byte =< $z) orelse
    (Byte >= $0 andalso Byte =< $9).

is_ascii_alnum(Byte) ->
    is_lower_alnum(Byte) orelse (Byte >= $A andalso Byte =< $Z).

has_control(Binary) ->
    lists:any(fun(Byte) -> Byte < 32 orelse Byte =:= 127 end,
              binary_to_list(Binary)).

valid_positive(Value) -> is_integer(Value) andalso Value > 0.

timed_call(Handle, RequestFun, CallOptions, DefaultTimeout) ->
    case adk_artifact_core:validate_call_options(CallOptions, DefaultTimeout) of
        {ok, Timeout, Deadline} ->
            safe_call(Handle, RequestFun(Deadline), Timeout);
        {error, _} = Error -> Error
    end.

safe_call(Handle, Request, Timeout)
  when is_pid(Handle), is_integer(Timeout), Timeout > 0 ->
    try gen_server:call(Handle, Request, Timeout) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, timeout};
        exit:{noproc, _} -> {error, unavailable};
        exit:_ -> {error, unavailable}
    end;
safe_call(_Handle, _Request, _Timeout) ->
    {error, invalid_handle}.

remaining(Deadline) ->
    erlang:max(0, Deadline - erlang:monotonic_time(millisecond)).
