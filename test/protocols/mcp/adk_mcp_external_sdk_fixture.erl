%% @doc Deterministic local endpoint for external MCP SDK conformance jobs.
%%
%% This module deliberately contains no SDK launcher, package download, shell
%% command, or network client.  A release job may start it inside an Erlang VM,
%% obtain descriptor/1, run its separately pinned SDK matrix, and then stop/1.
-module(adk_mcp_external_sdk_fixture).

-export([start/1, stop/1, descriptor/1, replace_generation/2]).

-spec start(map()) -> {ok, map()} | {error, term()}.
start(Options) when is_map(Options) ->
    Base = #{port => 0,
             tools => [echo_tool()],
             resources => [fixture_resource()],
             prompts => [fixture_prompt()],
             method_handlers => fixture_handlers(),
             modern_subscriptions => true,
             legacy_sse_compat => true},
    case adk_mcp_server:start(<<"streamable_http">>,
                              maps:merge(Base, Options)) of
        {ok, Server} ->
            case descriptor(Server) of
                {ok, Descriptor} ->
                    {ok, Descriptor#{server => Server}};
                {error, Reason} ->
                    _ = adk_mcp_server:stop(Server),
                    {error, Reason}
            end;
        {error, _} = Error -> Error
    end;
start(_Options) -> {error, invalid_mcp_external_fixture_options}.

-spec stop(pid() | map()) -> ok.
stop(#{server := Server}) -> stop(Server);
stop(Server) when is_pid(Server) -> adk_mcp_server:stop(Server).

-spec descriptor(pid()) -> {ok, map()} | {error, term()}.
descriptor(Server) when is_pid(Server) ->
    case {adk_mcp_server:endpoint(Server),
          adk_mcp_server:catalog_info(Server)} of
        {{ok, Endpoint}, {ok, Catalog}} ->
            {ok, #{endpoint => Endpoint,
                   catalog => Catalog,
                   protocol_versions => [<<"2026-07-28">>,
                                         <<"2025-11-25">>,
                                         <<"2025-06-18">>],
                   default_protocol => <<"2025-11-25">>,
                   modern_transport => stateless_streamable_http,
                   legacy_get_sse => optional_deprecated,
                   external_sdk_results => not_run}};
        {{error, Reason}, _} -> {error, Reason};
        {_, {error, Reason}} -> {error, Reason}
    end;
descriptor(_Server) -> {error, invalid_mcp_external_fixture}.

-spec replace_generation(pid() | map(), binary()) ->
    {ok, map()} | {error, term()}.
replace_generation(#{server := Server}, Name) ->
    replace_generation(Server, Name);
replace_generation(Server, Name) when is_pid(Server), is_binary(Name) ->
    adk_mcp_server:replace_catalog(
      Server, #{tools => [echo_tool(Name)],
                resources => [fixture_resource()],
                prompts => [fixture_prompt()]});
replace_generation(_Server, _Name) ->
    {error, invalid_mcp_external_fixture_generation}.

echo_tool() -> echo_tool(<<"fixture.echo">>).

echo_tool(Name) ->
    #{schema => #{<<"name">> => Name,
                  <<"description">> =>
                      <<"Deterministic external conformance echo">>,
                  <<"inputSchema">> =>
                      #{<<"type">> => <<"object">>,
                        <<"properties">> =>
                            #{<<"value">> => #{<<"type">> => <<"string">>}},
                        <<"required">> => [<<"value">>]}},
      execute => fun(Args, _Context) ->
          {ok, #{<<"echo">> => maps:get(<<"value">>, Args, <<>>)}}
      end}.

fixture_resource() ->
    #{uri => <<"fixture://resource">>, name => <<"fixture-resource">>,
      mime_type => <<"text/plain">>,
      read => fun() -> {ok, <<"fixture-resource-body">>} end}.

fixture_prompt() ->
    #{name => <<"fixture-prompt">>,
      get => fun(Arguments) ->
          Value = maps:get(<<"value">>, Arguments, <<"fixture">>),
          {ok, [#{<<"role">> => <<"user">>,
                  <<"content">> =>
                      #{<<"type">> => <<"text">>, <<"text">> => Value}}]}
      end}.

fixture_handlers() ->
    #{<<"completion/complete">> =>
          fun(_Params, _Context) ->
              {ok, #{<<"completion">> =>
                         #{<<"values">> => [<<"fixture-completion">>]}}}
          end,
      <<"logging/setLevel">> =>
          fun(Params, _Context) ->
              {ok, #{<<"level">> => maps:get(<<"level">>, Params)}}
          end,
      <<"roots/list">> =>
          fun(_Params, _Context) -> {ok, #{<<"roots">> => []}} end,
      <<"sampling/createMessage">> =>
          fun(_Params, _Context) ->
              {ok, #{<<"role">> => <<"assistant">>,
                     <<"content">> =>
                         #{<<"type">> => <<"text">>,
                           <<"text">> => <<"fixture-sample">>}}}
          end,
      <<"elicitation/create">> =>
          fun(_Params, _Context) ->
              {input_required,
               #{<<"confirm">> =>
                     #{<<"method">> => <<"elicitation/create">>,
                       <<"params">> =>
                           #{<<"mode">> => <<"form">>,
                             <<"message">> => <<"Confirm fixture?">>}}},
               <<"fixture-request-state">>}
          end}.
