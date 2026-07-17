%% @doc One bounded background memory-ingestion attempt sequence.
%%
%% Version-2 ingestion is safe to retry because event IDs become stable
%% idempotency keys. Legacy adapters are invoked once to avoid duplicating an
%% adapter whose old contract did not promise idempotency.
-module(adk_memory_ingest_worker).
-behaviour(gen_server).

-define(MAX_BATCH_EVENTS, 500).

-export([start_link/1, run/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

start_link(Spec) ->
    gen_server:start_link(?MODULE, Spec, []).

run(Spec) when is_map(Spec) ->
    case validate_spec(Spec) of
        ok -> perform(Spec);
        {error, _} = Error -> Error
    end;
run(_) ->
    {error, invalid_memory_ingestion_spec}.

init(Spec) ->
    case validate_spec(Spec) of
        ok -> {ok, Spec, {continue, ingest}};
        {error, Reason} -> {stop, Reason}
    end.

handle_continue(ingest, Spec) ->
    case perform(Spec) of
        ok -> {stop, normal, Spec};
        {error, Reason} ->
            logger:warning("Memory ingestion exhausted its bounded retries: ~p",
                           [Reason]),
            {stop, normal, Spec}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.
handle_cast(_Request, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

validate_spec(#{service := {Module, Handle},
                scope := {user, App, User},
                session_id := SessionId,
                events := Events,
                timeout := Timeout,
                max_attempts := Attempts})
  when is_atom(Module), Handle =/= undefined,
       is_binary(App), byte_size(App) > 0,
       is_binary(User), byte_size(User) > 0,
       is_binary(SessionId), byte_size(SessionId) > 0,
       is_list(Events), is_integer(Timeout), Timeout > 0,
       is_integer(Attempts), Attempts > 0, Attempts =< 10 ->
    ok;
validate_spec(_) ->
    {error, invalid_memory_ingestion_spec}.

perform(#{service := {Module, _} = Service,
          scope := Scope, session_id := SessionId,
          events := Events, timeout := Timeout,
          max_attempts := MaxAttempts}) ->
    case contract(Service, Module, Timeout) of
        v2 -> retry_v2(Service, Scope, SessionId, Events, Timeout,
                       MaxAttempts, 1);
        legacy -> normalize_reply(
                    adk_service_ref:call(
                      Service, add_session_to_memory,
                      [SessionId, Events], Timeout));
        {error, _} = Error -> Error
    end.

contract(Service, Module, Timeout) ->
    case erlang:function_exported(Module, capabilities, 1) of
        false -> legacy;
        true ->
            case adk_service_ref:call(Service, capabilities, [], Timeout) of
                #{contract_version := Version} when Version >= 2 -> v2;
                {ok, #{contract_version := Version}} when Version >= 2 -> v2;
                #{version := Version} when Version >= 2 -> v2;
                {ok, #{version := Version}} when Version >= 2 -> v2;
                {error, _} = Error -> Error;
                Other -> {error, {invalid_memory_capabilities, Other}}
            end
    end.

retry_v2(_Service, _Scope, _SessionId, [], _Timeout, _Max, _Attempt) -> ok;
retry_v2(Service, Scope, SessionId, Events, Timeout, Max, _Attempt) ->
    {Batch, Rest} = take_batch(Events, ?MAX_BATCH_EVENTS, []),
    case retry_v2_batch(Service, Scope, SessionId, Batch, Timeout, Max, 1) of
        ok -> retry_v2(Service, Scope, SessionId, Rest, Timeout, Max, 1);
        {error, _} = Error -> Error
    end.

retry_v2_batch({Module, _} = Service, Scope, SessionId, Events,
               Timeout, Max, Attempt) ->
    Reply = case erlang:function_exported(Module, add_events, 6) of
        true -> adk_service_ref:call(
                  Service, add_events,
                  [Scope, SessionId, Events, #{},
                   #{timeout_ms => operation_timeout(Timeout)}], Timeout);
        false -> {error, memory_deadline_unsupported}
    end,
    case normalize_reply(Reply) of
        ok -> ok;
        {error, _} when Attempt < Max ->
            timer:sleep(erlang:min(1000, 25 bsl (Attempt - 1))),
            retry_v2_batch(Service, Scope, SessionId, Events, Timeout,
                           Max, Attempt + 1);
        {error, _} = Error -> Error
    end.

take_batch(Rest, 0, Acc) -> {lists:reverse(Acc), Rest};
take_batch([], _Remaining, Acc) -> {lists:reverse(Acc), []};
take_batch([Event | Rest], Remaining, Acc) ->
    take_batch(Rest, Remaining - 1, [Event | Acc]).

operation_timeout(Timeout) when Timeout > 250 -> Timeout - 200;
operation_timeout(Timeout) -> erlang:max(1, Timeout div 2).

normalize_reply(ok) -> ok;
normalize_reply({ok, Result}) when is_map(Result) -> ok;
normalize_reply({error, _} = Error) -> Error;
normalize_reply(Other) -> {error, {invalid_memory_ingestion_reply, Other}}.
