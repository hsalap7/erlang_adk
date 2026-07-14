%% @doc Owner-private ETS credential store.
%%
%% The ETS table identifier is held by this gen_server and the table is
%% private, so raw credentials cannot be read by other processes. Public
%% operations always require the original principal and provider scope.
-module(adk_credential_store_ets).

-behaviour(gen_server).
-behaviour(adk_credential_store).

-export([start_link/0, start_link/1, child_spec/1, put/4, fetch/4, delete/4,
         compare_and_swap/6]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-record(state, {table :: ets:tid()}).

-type server() :: gen_server:server_ref().

-spec start_link() -> gen_server:start_ret().
start_link() ->
    start_link(#{}).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Opts) when is_map(Opts) ->
    case maps:get(name, Opts, ?MODULE) of
        undefined -> gen_server:start_link(?MODULE, Opts, []);
        Name when is_atom(Name) ->
            gen_server:start_link({local, Name}, ?MODULE, Opts, [])
    end.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Opts) ->
    #{id => maps:get(id, Opts, ?MODULE),
      start => {?MODULE, start_link, [Opts]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec put(server(), adk_credential_store:principal(),
          adk_credential_store:provider_id(),
          adk_credential_store:credential()) ->
    {ok, adk_credential_store:credential_ref()} |
    {error, adk_credential_store:error_reason()}.
put(Server, Principal, Provider, Credential) ->
    gen_server:call(Server, {put, Principal, Provider, Credential}).

-spec fetch(server(), adk_credential_store:principal(),
            adk_credential_store:provider_id(),
            adk_credential_store:credential_ref()) ->
    {ok, adk_credential_store:credential()} |
    {error, adk_credential_store:error_reason()}.
fetch(Server, Principal, Provider, Ref) ->
    gen_server:call(Server, {fetch, Principal, Provider, Ref}).

-spec delete(server(), adk_credential_store:principal(),
             adk_credential_store:provider_id(),
             adk_credential_store:credential_ref()) ->
    ok | {error, adk_credential_store:error_reason()}.
delete(Server, Principal, Provider, Ref) ->
    gen_server:call(Server, {delete, Principal, Provider, Ref}).

%% @doc Atomically replace a credential while keeping the same opaque
%% reference. The gen_server owns the private ETS table, so the comparison and
%% replacement are serialized with fetch/delete/put operations.
-spec compare_and_swap(server(), adk_credential_store:principal(),
                       adk_credential_store:provider_id(),
                       adk_credential_store:credential_ref(),
                       adk_credential_store:credential(),
                       adk_credential_store:credential()) ->
    ok | {error, adk_credential_store:error_reason()}.
compare_and_swap(Server, Principal, Provider, Ref, Expected, Replacement) ->
    gen_server:call(Server,
                    {compare_and_swap, Principal, Provider, Ref,
                     Expected, Replacement}).

init(_Opts) ->
    Table = ets:new(?MODULE, [set, private,
                              {read_concurrency, true},
                              {write_concurrency, true}]),
    {ok, #state{table = Table}}.

handle_call({put, Principal, Provider, Credential}, _From,
            State = #state{table = Table}) ->
    case valid_input(Principal, Provider, Credential) of
        ok ->
            Ref = adk_credential_store:new_ref(),
            true = ets:insert(Table, {Ref, Principal, Provider, Credential}),
            {reply, {ok, Ref}, State};
        {error, _} = Error ->
            {reply, Error, State}
    end;
handle_call({fetch, Principal, Provider, Ref}, _From,
            State = #state{table = Table}) ->
    Reply = case ets:lookup(Table, Ref) of
        [{Ref, Principal, Provider, Credential}] -> {ok, Credential};
        _ -> {error, not_found}
    end,
    {reply, Reply, State};
handle_call({delete, Principal, Provider, Ref}, _From,
            State = #state{table = Table}) ->
    Reply = case ets:lookup(Table, Ref) of
        [{Ref, Principal, Provider, _Credential}] ->
            true = ets:delete(Table, Ref),
            ok;
        _ ->
            {error, not_found}
    end,
    {reply, Reply, State};
handle_call({compare_and_swap, Principal, Provider, Ref,
             Expected, Replacement}, _From,
            State = #state{table = Table}) ->
    Reply = compare_and_swap_credential(
              Table, Principal, Provider, Ref, Expected, Replacement),
    {reply, Reply, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unavailable}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Keep raw credentials out of sys status and abnormal-termination reports.
format_status(Status) ->
    maps:map(
      fun(state, _State) -> credential_store_private;
         (message, Message) -> redact_store_message(Message);
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, Value) -> adk_secret_redactor:redact(Value)
      end, Status).

redact_store_message({'$gen_call', From,
                      {put, Principal, Provider, _Credential}}) ->
    {'$gen_call', From,
     {put, Principal, Provider, adk_secret_redactor:marker()}};
redact_store_message({put, Principal, Provider, _Credential}) ->
    {put, Principal, Provider, adk_secret_redactor:marker()};
redact_store_message({'$gen_call', From,
                      {compare_and_swap, Principal, Provider, Ref,
                       _Expected, _Replacement}}) ->
    {'$gen_call', From,
     {compare_and_swap, Principal, Provider, Ref,
      adk_secret_redactor:marker(), adk_secret_redactor:marker()}};
redact_store_message({compare_and_swap, Principal, Provider, Ref,
                      _Expected, _Replacement}) ->
    {compare_and_swap, Principal, Provider, Ref,
     adk_secret_redactor:marker(), adk_secret_redactor:marker()};
redact_store_message(Message) ->
    adk_secret_redactor:redact(Message).

compare_and_swap_credential(Table, Principal, Provider, Ref,
                            Expected, Replacement) ->
    case {valid_input(Principal, Provider, Expected),
          valid_input(Principal, Provider, Replacement)} of
        {ok, ok} ->
            case ets:lookup(Table, Ref) of
                [{Ref, Principal, Provider, Expected}] ->
                    true = ets:insert(
                             Table,
                             {Ref, Principal, Provider, Replacement}),
                    ok;
                [{Ref, Principal, Provider, _Current}] ->
                    {error, conflict};
                _ ->
                    {error, not_found}
            end;
        {{error, invalid_scope}, _} -> {error, invalid_scope};
        {_, {error, invalid_scope}} -> {error, invalid_scope};
        _ -> {error, invalid_credential}
    end.

valid_input(Principal, Provider, Credential) when is_map(Credential) ->
    case valid_identity(Principal) andalso valid_identity(Provider) of
        true -> ok;
        false -> {error, invalid_scope}
    end;
valid_input(_Principal, _Provider, _Credential) ->
    {error, invalid_credential}.

valid_identity(Value) when is_binary(Value) -> byte_size(Value) > 0;
valid_identity(Value) when is_atom(Value) -> Value =/= undefined;
valid_identity(_) -> false.
