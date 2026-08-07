-module(adk_agent_provider_capability_test).

-include_lib("eunit/include/eunit.hrl").

generation_config_agents_construct_for_native_providers_test() ->
    {ok, _} = application:ensure_all_started(erlang_adk),
    Configs =
        [#{provider => adk_llm_openai,
           model => <<"gpt-test">>,
           base_url => <<"https://openai.example.test/v1">>,
           api_key => <<"test-openai-key">>,
           temperature => 0.2},
         #{provider => adk_llm_anthropic,
           model => <<"claude-test">>,
           base_url => <<"https://anthropic.example.test/v1">>,
           api_key => <<"test-anthropic-key">>,
           temperature => 0.2},
         #{provider => adk_llm_compatible,
           model => <<"compatible-test">>,
           base_url => <<"https://compatible.example.test/v1">>,
           auth_scheme => none,
           temperature => 0.2}],
    lists:foreach(fun assert_agent_constructs/1, Configs).

assert_agent_constructs(Config) ->
    Provider = maps:get(provider, Config),
    {ok, Capabilities} = adk_llm:capabilities(Config),
    ?assert(adk_provider_capabilities:supports(
              Capabilities, generation_config)),
    Name = <<"GenerationConfig_",
             (atom_to_binary(Provider, utf8))/binary, "_",
             (integer_to_binary(
                erlang:unique_integer([positive, monotonic])))/binary>>,
    {ok, Agent} = erlang_adk:spawn_agent(Name, Config, []),
    ok = erlang_adk:stop_agent(Agent).
