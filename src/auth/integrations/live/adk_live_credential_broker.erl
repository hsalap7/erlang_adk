%% @doc Opaque, process-scoped storage for reconnectable Live credentials.
%%
%% The secret is kept in a private ETS table rather than in the broker or
%% session state returned by OTP system inspection.  The returned reference is
%% a capability: only code which already possesses it can resolve the secret.
%% The table is destroyed when the session owner exits or explicitly revokes
%% the reference.
-module(adk_live_credential_broker).
-behaviour(gen_server).

-export([start/2, resolve/1, revoke/1, valid_ref/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-opaque credential_ref() ::
    {adk_live_credential, pid(), reference()}.
-export_type([credential_ref/0]).

-define(CALL_TIMEOUT_MS, 5000).

-spec start(pid(), binary()) ->
    {ok, credential_ref()} | {error, invalid_credential}.
start(Owner, Secret)
  when is_pid(Owner), is_binary(Secret), byte_size(Secret) > 0,
       byte_size(Secret) =< 4096 ->
    Token = make_ref(),
    case gen_server:start(?MODULE, {Owner, Token, Secret}, []) of
        {ok, Pid} -> {ok, {adk_live_credential, Pid, Token}};
        {error, _} -> {error, invalid_credential}
    end;
start(_Owner, _Secret) ->
    {error, invalid_credential}.

-spec resolve(credential_ref()) ->
    {ok, binary()} | {error, credential_unavailable}.
resolve({adk_live_credential, Pid, Token})
  when is_pid(Pid), is_reference(Token) ->
    try gen_server:call(Pid, {resolve, Token}, ?CALL_TIMEOUT_MS) of
        {ok, Secret} when is_binary(Secret) -> {ok, Secret};
        _ -> {error, credential_unavailable}
    catch
        exit:_ -> {error, credential_unavailable}
    end;
resolve(_Reference) ->
    {error, credential_unavailable}.

-spec revoke(credential_ref()) -> ok.
revoke({adk_live_credential, Pid, Token})
  when is_pid(Pid), is_reference(Token) ->
    try gen_server:call(Pid, {revoke, Token}, ?CALL_TIMEOUT_MS) of
        ok -> ok
    catch
        exit:_ -> ok
    end;
revoke(_Reference) -> ok.

-spec valid_ref(term()) -> boolean().
valid_ref({adk_live_credential, Pid, Token}) ->
    is_pid(Pid) andalso is_reference(Token);
valid_ref(_Reference) -> false.

init({Owner, Token, Secret}) ->
    process_flag(message_queue_data, off_heap),
    Table = ets:new(?MODULE, [set, private]),
    true = ets:insert(Table, {credential, Secret}),
    OwnerMonitor = erlang:monitor(process, Owner),
    {ok, #{table => Table, token => Token,
           owner_monitor => OwnerMonitor}}.

handle_call({resolve, Token}, _From, #{token := Token,
                                      table := Table} = State) ->
    case ets:lookup(Table, credential) of
        [{credential, Secret}] -> {reply, {ok, Secret}, State};
        [] -> {reply, {error, credential_unavailable}, State}
    end;
handle_call({resolve, _Token}, _From, State) ->
    {reply, {error, credential_unavailable}, State};
handle_call({revoke, Token}, _From, #{token := Token} = State) ->
    {stop, normal, ok, State};
handle_call({revoke, _Token}, _From, State) ->
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, bad_request}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', Monitor, process, _Owner, _Reason},
            #{owner_monitor := Monitor} = State) ->
    {stop, normal, State};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, #{table := Table}) ->
    _ = catch ets:delete(Table),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

format_status(Status) ->
    maps:map(
      fun(state, State) when is_map(State) ->
              #{configured => maps:is_key(table, State)};
         (message, _Message) -> adk_secret_redactor:marker();
         (log, _Log) -> [];
         (reason, _Reason) -> adk_secret_redactor:marker();
         (_Key, _Value) -> adk_secret_redactor:marker()
      end, Status).
