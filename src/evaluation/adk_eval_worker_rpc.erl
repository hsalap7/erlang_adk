%% @doc Explicit-node distributed evaluation worker transport.
%%
%% A local proxy monitors both the evaluation service and the remote worker.
%% Cancellation kills the remote coordinator, which is linked to the actual
%% evaluator, so an evaluation never keeps running after its owner disappears.
%% Nodes are an operator allowlist; no node name comes from an eval document.
-module(adk_eval_worker_rpc).
-behaviour(adk_eval_worker).

-export([start/3, cancel/2, capabilities/1, remote_coordinator/5]).

-define(DEFAULT_TIMEOUT_MS, 3600000).
-define(MAX_TIMEOUT_MS, 86400000).
-define(DEFAULT_MAX_HEAP_WORDS, 2097152).
-define(MAX_HEAP_WORDS, 8388608).

-spec start(map(), pid(), map()) ->
    {ok, reference(), map()} | {error, term()}.
start(Request, Owner, Config0) when is_map(Request), is_pid(Owner),
                                   is_map(Config0) ->
    case normalize_config(Config0) of
        {error, _} = Error -> Error;
        {ok, Config} ->
            case select_node(maps:get(nodes, Config)) of
                {error, _} = Error -> Error;
                {ok, Node} ->
                    Ref = make_ref(),
                    Parent = self(),
                    Proxy = spawn_opt(
                              fun() -> proxy_init(
                                         Parent, Owner, Ref, Node,
                                         Request, Config)
                              end,
                              [{message_queue_data, off_heap}]),
                    receive
                        {adk_eval_rpc_worker_ready, Ref, Proxy,
                         {ok, RemotePid}} ->
                            {ok, Ref, #{proxy => Proxy, remote => RemotePid,
                                       ref => Ref}};
                        {adk_eval_rpc_worker_ready, Ref, Proxy,
                         {error, Reason}} ->
                            {error, Reason}
                    after 5000 ->
                        exit(Proxy, kill),
                        {error, eval_worker_start_timeout}
                    end
            end
    end;
start(_Request, _Owner, _Config) -> {error, invalid_eval_worker_config}.

-spec cancel(map(), term()) -> ok | {error, term()}.
cancel(#{proxy := Proxy, ref := Ref}, Reason)
  when is_pid(Proxy), is_reference(Ref) ->
    Alias = erlang:alias([reply]),
    Monitor = erlang:monitor(process, Proxy),
    Proxy ! {adk_eval_worker_cancel, Ref, self(), Alias, Reason},
    receive
        {adk_eval_worker_cancelled, Alias, Reply} ->
            _ = erlang:unalias(Alias),
            erlang:demonitor(Monitor, [flush]),
            Reply;
        {'DOWN', Monitor, process, Proxy, _} ->
            _ = erlang:unalias(Alias),
            {error, not_found}
    after 5000 ->
        _ = erlang:unalias(Alias),
        erlang:demonitor(Monitor, [flush]),
        {error, eval_worker_cancel_timeout}
    end;
cancel(_Handle, _Reason) -> {error, not_found}.

-spec capabilities(map()) -> map().
capabilities(Config) ->
    case normalize_config(Config) of
        {ok, Safe} ->
            #{transport => rpc, contract_version => 1,
              configured_nodes => length(maps:get(nodes, Safe)),
              cancellation => owner_bound_remote_kill,
              replay => never};
        {error, _} -> #{transport => rpc, status => invalid_config}
    end.

%% Exported only as the remote spawn entry point.
-spec remote_coordinator(pid(), reference(), map(), pos_integer(),
                         pos_integer()) -> no_return().
remote_coordinator(Proxy, Ref, Request, Timeout, MaxHeapWords) ->
    process_flag(trap_exit, true),
    ProxyMonitor = erlang:monitor(process, Proxy),
    Coordinator = self(),
    Child = spawn_opt(
              fun() ->
                  Result = try run_request(Request) of
                      Reply -> Reply
                  catch
                      _:_ -> {error, evaluation_worker_failed}
                  end,
                  Coordinator ! {adk_eval_remote_result, Ref, self(), Result}
              end,
              [link, {message_queue_data, off_heap},
               {max_heap_size,
                #{size => MaxHeapWords, kill => true, error_logger => false,
                  include_shared_binaries => true}}]),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    remote_loop(Proxy, ProxyMonitor, Ref, Child, Deadline).

proxy_init(Parent, Owner, Ref, Node, Request, Config) ->
    OwnerMonitor = erlang:monitor(process, Owner),
    Timeout = maps:get(timeout_ms, Config),
    Heap = maps:get(max_heap_words, Config),
    try spawn_opt(Node, ?MODULE, remote_coordinator,
                  [self(), Ref, Request, Timeout, Heap], [monitor]) of
        {RemotePid, RemoteMonitor} ->
            Parent ! {adk_eval_rpc_worker_ready, Ref, self(),
                      {ok, RemotePid}},
            proxy_loop(Owner, OwnerMonitor, Ref, RemotePid, RemoteMonitor)
    catch
        _:_ ->
            Parent ! {adk_eval_rpc_worker_ready, Ref, self(),
                      {error, eval_worker_node_unavailable}}
    end.

proxy_loop(Owner, OwnerMonitor, Ref, RemotePid, RemoteMonitor) ->
    receive
        {adk_eval_remote_terminal, Ref, RemotePid, Outcome} ->
            erlang:demonitor(RemoteMonitor, [flush]),
            erlang:demonitor(OwnerMonitor, [flush]),
            Owner ! {adk_eval_worker_terminal, ?MODULE, Ref, Outcome};
        {adk_eval_worker_cancel, Ref, Caller, Alias, Reason} ->
            exit(RemotePid, kill),
            erlang:demonitor(RemoteMonitor, [flush]),
            erlang:demonitor(OwnerMonitor, [flush]),
            Caller ! {adk_eval_worker_cancelled, Alias, ok},
            Owner ! {adk_eval_worker_terminal, ?MODULE, Ref,
                     {cancelled, safe_reason(Reason)}};
        {'DOWN', OwnerMonitor, process, Owner, _Reason} ->
            exit(RemotePid, kill),
            ok;
        {'DOWN', RemoteMonitor, process, RemotePid, Reason} ->
            erlang:demonitor(OwnerMonitor, [flush]),
            Owner ! {adk_eval_worker_terminal, ?MODULE, Ref,
                     {failed, remote_reason(Reason)}};
        _Other -> proxy_loop(Owner, OwnerMonitor, Ref,
                             RemotePid, RemoteMonitor)
    end.

remote_loop(Proxy, ProxyMonitor, Ref, Child, Deadline) ->
    Remaining = erlang:max(
                  0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {adk_eval_remote_result, Ref, Child, Result} ->
            Proxy ! {adk_eval_remote_terminal, Ref, self(),
                     {completed, Result}},
            erlang:demonitor(ProxyMonitor, [flush]),
            exit(normal);
        {'DOWN', ProxyMonitor, process, Proxy, _Reason} ->
            exit(Child, kill),
            exit(normal);
        {'EXIT', Child, Reason} when Reason =/= normal ->
            Proxy ! {adk_eval_remote_terminal, Ref, self(),
                     {failed, remote_reason(Reason)}},
            erlang:demonitor(ProxyMonitor, [flush]),
            exit(normal);
        _Other -> remote_loop(Proxy, ProxyMonitor, Ref, Child, Deadline)
    after Remaining ->
        exit(Child, kill),
        Proxy ! {adk_eval_remote_terminal, Ref, self(),
                 {timed_out, <<"deadline_exceeded">>}},
        erlang:demonitor(ProxyMonitor, [flush]),
        exit(normal)
    end.

run_request(#{adapter := Adapter, set := Set, metrics := Metrics,
              options := Options}) ->
    adk_eval_set:run(Adapter, Set, Metrics, Options).

normalize_config(Config) ->
    Allowed = [nodes, timeout_ms, max_heap_words],
    Unknown = maps:keys(maps:without(Allowed, Config)),
    Nodes = maps:get(nodes, Config, [node()]),
    Timeout = maps:get(timeout_ms, Config, ?DEFAULT_TIMEOUT_MS),
    Heap = maps:get(max_heap_words, Config, ?DEFAULT_MAX_HEAP_WORDS),
    case {Unknown, valid_nodes(Nodes), within(Timeout, 1, ?MAX_TIMEOUT_MS),
          within(Heap, 1024, ?MAX_HEAP_WORDS)} of
        {[], true, true, true} ->
            {ok, #{nodes => Nodes, timeout_ms => Timeout,
                   max_heap_words => Heap}};
        {[_ | _], _, _, _} ->
            {error, {unknown_eval_worker_options, lists:sort(Unknown)}};
        _ -> {error, invalid_eval_worker_config}
    end.

valid_nodes(Nodes) -> valid_nodes(Nodes, 0, #{}).
valid_nodes([], Count, _Seen) -> Count > 0;
valid_nodes([Node | Rest], Count, Seen)
  when is_atom(Node), Count < 64 ->
    case maps:is_key(Node, Seen) of
        true -> false;
        false -> valid_nodes(Rest, Count + 1, Seen#{Node => true})
    end;
valid_nodes(_, _Count, _Seen) -> false.

select_node([Node | Rest]) ->
    case Node =:= node() orelse lists:member(Node, nodes(connected)) of
        true -> {ok, Node};
        false -> select_node(Rest)
    end;
select_node([]) -> {error, eval_worker_node_unavailable}.

within(Value, Minimum, Maximum) ->
    is_integer(Value) andalso Value >= Minimum andalso Value =< Maximum.

remote_reason(noconnection) -> <<"node_unavailable">>;
remote_reason(_Reason) -> <<"remote_worker_failed">>.

safe_reason(Reason) ->
    try adk_secret_redactor:redact(Reason) of
        Value -> Value
    catch
        _:_ -> <<"cancelled">>
    end.
