%% @doc Optional OTP owner for atomic MCP catalog generation swaps.
%%
%% The pure adk_mcp_catalog value already provides immutable snapshots. This
%% small process supplies a single serialized swap point for applications that
%% want concurrent readers to obtain one current generation without adding the
%% service to erlang_adk's supervision tree.
-module(adk_mcp_catalog_store).
-behaviour(gen_server).

-export([start_link/0, start_link/1, child_spec/1, replace_all/2,
         snapshot/1, list/4, lookup/3, describe/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, format_status/1]).

-define(CALL_TIMEOUT_MS, 5000).

-spec start_link() -> gen_server:start_ret().
start_link() -> start_link(#{}).

-spec start_link(map()) -> gen_server:start_ret().
start_link(Definitions) when is_map(Definitions) ->
    gen_server:start_link(?MODULE, Definitions, []);
start_link(_Definitions) ->
    {error, invalid_mcp_catalog_definitions}.

-spec child_spec(map()) -> supervisor:child_spec().
child_spec(Definitions) ->
    #{id => {?MODULE, make_ref()},
      start => {?MODULE, start_link, [Definitions]},
      restart => permanent,
      shutdown => 5000,
      type => worker,
      modules => [?MODULE]}.

-spec replace_all(gen_server:server_ref(), map()) ->
    {ok, map()} | {error, term()}.
replace_all(Server, Definitions) ->
    safe_call(Server, {replace_all, Definitions}).

-spec snapshot(gen_server:server_ref()) ->
    {ok, adk_mcp_catalog:snapshot()} | {error, term()}.
snapshot(Server) -> safe_call(Server, snapshot).

-spec list(gen_server:server_ref(), adk_mcp_catalog:kind(),
           undefined | binary(), pos_integer()) ->
    {ok, map()} | {error, term()}.
list(Server, Kind, Cursor, Limit) ->
    safe_call(Server, {list, Kind, Cursor, Limit}).

-spec lookup(gen_server:server_ref(), adk_mcp_catalog:kind(), binary()) ->
    {ok, map()} | {error, term()}.
lookup(Server, Kind, Id) ->
    safe_call(Server, {lookup, Kind, Id}).

-spec describe(gen_server:server_ref()) -> {ok, map()} | {error, term()}.
describe(Server) -> safe_call(Server, describe).

init(Definitions) ->
    case adk_mcp_catalog:new(Definitions) of
        {ok, Catalog} -> {ok, #{catalog => Catalog}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call(snapshot, _From, #{catalog := Catalog} = State) ->
    {reply, adk_mcp_catalog:snapshot(Catalog), State};
handle_call(describe, _From, #{catalog := Catalog} = State) ->
    {reply, adk_mcp_catalog:describe(Catalog), State};
handle_call({lookup, Kind, Id}, _From, #{catalog := Catalog} = State) ->
    {reply, adk_mcp_catalog:lookup(Catalog, Kind, Id), State};
handle_call({list, Kind, Cursor, Limit}, _From,
            #{catalog := Catalog} = State) ->
    {reply, adk_mcp_catalog:list(Catalog, Kind, Cursor, Limit), State};
handle_call({replace_all, Definitions}, _From,
            #{catalog := Catalog0} = State) ->
    case adk_mcp_catalog:replace(Catalog0, Definitions) of
        {ok, Catalog} ->
            {ok, Change} = adk_mcp_catalog:list_changed(Catalog0, Catalog),
            {reply, {ok, Change}, State#{catalog => Catalog}};
        {error, _} = Error -> {reply, Error, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, invalid_mcp_catalog_store_request}, State}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info(_Message, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.

%% Never expose catalog entries through crash/status formatting. The public
%% description contains only generations, opaque lineage ids, and counts.
format_status(Status) when is_map(Status) ->
    maps:map(
      fun(state, #{catalog := Catalog}) ->
              case adk_mcp_catalog:describe(Catalog) of
                  {ok, Description} -> Description;
                  {error, _} -> #{status => invalid_catalog}
              end;
         (message, _Message) -> redacted;
         (log, _Log) -> [];
         (reason, _Reason) -> redacted;
         (_Key, Value) -> Value
      end, Status);
format_status(Status) -> Status.

safe_call(Server, Request) ->
    try gen_server:call(Server, Request, ?CALL_TIMEOUT_MS) of
        Reply -> Reply
    catch
        exit:{timeout, _} -> {error, mcp_catalog_store_timeout};
        exit:{noproc, _} -> {error, mcp_catalog_store_unavailable};
        exit:{normal, _} -> {error, mcp_catalog_store_unavailable};
        exit:{shutdown, _} -> {error, mcp_catalog_store_unavailable};
        _:_ -> {error, mcp_catalog_store_unavailable}
    end.
