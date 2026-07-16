%% Offline test double for the Oidcc provider worker read interface.
-module(adk_oidcc_fixture_provider).

-behaviour(gen_server).

-include_lib("oidcc/include/oidcc_provider_configuration.hrl").

-export([start_link/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

start_link(Issuer, Jwks) ->
    gen_server:start_link(?MODULE, {Issuer, Jwks}, []).

init({Issuer, Jwks}) ->
    Configuration = #oidcc_provider_configuration{
                       issuer = Issuer,
                       authorization_endpoint =
                           <<Issuer/binary, "/authorize">>,
                       scopes_supported = [],
                       response_types_supported = [<<"code">>],
                       subject_types_supported = [public],
                       id_token_signing_alg_values_supported = [<<"RS256">>]},
    {ok, #{configuration => Configuration, jwks => Jwks}}.

handle_call(get_provider_configuration, _From,
            #{configuration := Configuration} = State) ->
    {reply, Configuration, State};
handle_call(get_jwks, _From, #{jwks := Jwks} = State) ->
    {reply, Jwks, State};
handle_call(_Request, _From, State) ->
    {reply, undefined, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVersion, State, _Extra) -> {ok, State}.
