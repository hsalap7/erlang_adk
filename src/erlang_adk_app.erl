%%%-------------------------------------------------------------------
%% @doc erlang_adk public API
%% @end
%%%-------------------------------------------------------------------

-module(erlang_adk_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    erlang_adk_session:init(),
    erlang_adk_session_mnesia:init(),
    
    %% Start Cowboy A2A listener
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/a2a/prompt", erlang_adk_a2a_handler, []}
        ]}
    ]),
    case cowboy:start_clear(http,
        [{port, 8080}],
        #{env => #{dispatch => Dispatch}}
    ) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok;
        {error, eaddrinuse} -> ok
    end,
    
    erlang_adk_sup:start_link().

stop(_State) ->
    cowboy:stop_listener(http),
    ok.

%% internal functions
