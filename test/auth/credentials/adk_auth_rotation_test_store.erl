%% Deterministic credential store used to inject rotation persistence failures.
-module(adk_auth_rotation_test_store).

-behaviour(gen_server).
-behaviour(adk_credential_store).

-export([start_link/1, put/4, fetch/4, delete/4, compare_and_swap/6]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

start_link(Mode) ->
    gen_server:start_link(?MODULE, Mode, []).

put(Server, Principal, Provider, Credential) ->
    gen_server:call(Server, {put, Principal, Provider, Credential}).

fetch(Server, Principal, Provider, Ref) ->
    gen_server:call(Server, {fetch, Principal, Provider, Ref}).

delete(Server, Principal, Provider, Ref) ->
    gen_server:call(Server, {delete, Principal, Provider, Ref}).

compare_and_swap(Server, Principal, Provider, Ref, Expected, Replacement) ->
    gen_server:call(Server,
                    {compare_and_swap, Principal, Provider, Ref,
                     Expected, Replacement}).

init(Mode) ->
    {ok, #{mode => Mode, entry => undefined}}.

handle_call({put, Principal, Provider, Credential}, _From, State) ->
    Ref = adk_credential_store:new_ref(),
    {reply, {ok, Ref},
     State#{entry => {Ref, Principal, Provider, Credential}}};
handle_call({fetch, Principal, Provider, Ref}, _From,
            #{entry := {Ref, Principal, Provider, Credential}} = State) ->
    {reply, {ok, Credential}, State};
handle_call({fetch, _Principal, _Provider, _Ref}, _From, State) ->
    {reply, {error, not_found}, State};
handle_call({compare_and_swap, _Principal, _Provider, _Ref,
             _Expected, _Replacement}, _From,
            #{mode := unavailable} = State) ->
    {reply, {error, unavailable}, State};
handle_call({compare_and_swap, _Principal, _Provider, _Ref,
             _Expected, _Replacement}, _From,
            #{mode := conflict} = State) ->
    {reply, {error, conflict}, State};
handle_call({compare_and_swap, Principal, Provider, Ref,
             Expected, Replacement}, _From,
            #{entry := {Ref, Principal, Provider, Expected}} = State) ->
    {reply, ok,
     State#{entry => {Ref, Principal, Provider, Replacement}}};
handle_call({compare_and_swap, _Principal, _Provider, _Ref,
             _Expected, _Replacement}, _From, State) ->
    {reply, {error, conflict}, State};
handle_call({delete, Principal, Provider, Ref}, _From,
            #{entry := {Ref, Principal, Provider, _Credential}} = State) ->
    {reply, ok, State#{entry => undefined}};
handle_call({delete, _Principal, _Provider, _Ref}, _From, State) ->
    {reply, {error, not_found}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unavailable}, State}.

handle_cast(_Request, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVersion, State, _Extra) -> {ok, State}.

format_status(Status) ->
    maps:map(
      fun(state, #{mode := Mode}) -> #{mode => Mode, entry => private};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, Value) -> adk_secret_redactor:redact(Value)
      end, Status).
