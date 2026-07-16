-module(adk_memory_probe_service).
-behaviour(adk_memory_service).

-export([init/1, add/3, search/4, delete/2, add_session_to_memory/3]).

init(Config) ->
    {ok, Config}.

add(Handle, Content, Metadata) ->
    notify(Handle, {memory_add, Content, Metadata}),
    maps:get(add_reply, Handle, {ok, <<"probe-memory-id">>}).

search(Handle, Query, Filter, Limit) ->
    notify(Handle, {memory_search, Query, Filter, Limit}),
    case maps:get(report_worker, Handle, false) of
        true -> notify(Handle, {memory_service_worker, self()});
        false -> ok
    end,
    maybe_delay(Handle),
    maps:get(search_reply, Handle, {ok, []}).

delete(Handle, Id) ->
    notify(Handle, {memory_delete, Id}),
    maps:get(delete_reply, Handle, ok).

add_session_to_memory(Handle, SessionId, Events) ->
    notify(Handle, {memory_ingested, SessionId, Events}),
    maybe_delay(Handle),
    maps:get(ingestion_reply, Handle, ok).

notify(Handle, Message) ->
    case maps:get(test_pid, Handle, undefined) of
        Pid when is_pid(Pid) -> Pid ! Message;
        _ -> ok
    end.

maybe_delay(Handle) ->
    case maps:get(delay_ms, Handle, 0) of
        Delay when is_integer(Delay), Delay > 0 -> timer:sleep(Delay);
        _ -> ok
    end.
