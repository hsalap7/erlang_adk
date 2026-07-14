-module(adk_context_cache_fake_provider).

-behaviour(adk_context_cache_provider).

-export([capabilities/0, create/2, delete/2,
         reset/1, stats/0, last_prefix/0, last_worker/0]).

-define(TABLE, adk_context_cache_fake_provider_state).

capabilities() ->
    #{context_cache => true,
      semantics => provider_request_prefix_cache,
      response_cache => false}.

reset(Mode) ->
    case ets:whereis(?TABLE) of
        undefined -> ok;
        _ -> ets:delete(?TABLE)
    end,
    _ = ets:new(?TABLE, [named_table, public, set,
                         {write_concurrency, true}]),
    true = ets:insert(?TABLE, [{mode, Mode}, {creates, 0}, {deletes, 0},
                               {max_delete_active, 0}]),
    ok.

stats() ->
    #{creates => value(creates, 0), deletes => value(deletes, 0),
      max_delete_active => value(max_delete_active, 0)}.

last_prefix() -> value(last_prefix, undefined).

last_worker() -> value(last_worker, undefined).

create(Prefix, _Request) ->
    Number = ets:update_counter(?TABLE, creates, 1),
    true = ets:insert(?TABLE, [{last_prefix, Prefix},
                               {last_worker, self()}]),
    case value(mode, success) of
        success -> success(Number);
        {delay, Milliseconds} -> timer:sleep(Milliseconds), success(Number);
        {controlled, Owner} when is_pid(Owner) ->
            Owner ! {cache_provider_waiting, self()},
            receive cache_provider_release -> success(Number) end;
        fail -> {error, fixture_provider_failure};
        crash -> erlang:error(fixture_provider_crash);
        hang -> receive fixture_never_sent -> ok end;
        {delete_delay, _Milliseconds} -> success(Number);
        invalid_resource -> {ok, #{invalid => resource}}
    end.

delete(_Resource, _Request) ->
    _ = ets:update_counter(?TABLE, deletes, 1),
    WorkerKey = {delete_worker, self()},
    true = ets:insert(?TABLE, {WorkerKey, true}),
    Active = ets:select_count(
               ?TABLE,
               [{{{delete_worker, '_'}, '_'}, [], [true]}]),
    Previous = value(max_delete_active, 0),
    true = ets:insert(?TABLE,
                      {max_delete_active, erlang:max(Previous, Active)}),
    case value(mode, success) of
        {delete_delay, Milliseconds} -> timer:sleep(Milliseconds);
        _ -> ok
    end,
    ets:delete(?TABLE, WorkerKey),
    ok.

success(Number) ->
    Resource = <<"provider-cache-resource-", (integer_to_binary(Number))/binary>>,
    {ok, Resource,
     #{<<"resource_name">> => Resource,
       <<"api_key">> => <<"must-not-escape">>,
       <<"cached_tokens">> => 42}}.

value(Key, Default) ->
    case ets:lookup(?TABLE, Key) of
        [{Key, Value}] -> Value;
        [] -> Default
    end.
