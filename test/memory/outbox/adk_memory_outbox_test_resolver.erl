-module(adk_memory_outbox_test_resolver).
-behaviour(adk_memory_outbox_resolver).

-export([resolve/3]).

resolve(AdapterModule, StableId,
        #{mode := Mode, service_ref := ServiceRef} = State) ->
    notify(maps:get(test_pid, State, undefined),
           {memory_outbox_resolver_started, self(), Mode,
            AdapterModule, StableId}),
    resolve_mode(Mode, ServiceRef).

resolve_mode(hang, _ServiceRef) ->
    receive memory_outbox_resolver_never_sent ->
        {error, unexpected_resolver_release}
    end;
resolve_mode(block, ServiceRef) ->
    receive
        memory_outbox_resolver_release -> {ok, ServiceRef}
    end;
resolve_mode({delay, Milliseconds}, ServiceRef)
  when is_integer(Milliseconds), Milliseconds >= 0 ->
    timer:sleep(Milliseconds),
    {ok, ServiceRef};
resolve_mode(immediate, ServiceRef) ->
    {ok, ServiceRef}.

notify(Pid, Message) when is_pid(Pid) -> Pid ! Message;
notify(_, _) -> ok.
