-module(adk_web_gateway_test_authorizer).

-behaviour(adk_authorizer).

-export([new/1, authorize/4]).

new(#{mode := Mode, policy := PolicyConfig} = Config) ->
    case adk_scope_authorizer:new(PolicyConfig) of
        {ok, Policy} ->
            {ok, #{mode => Mode, policy => Policy,
                   observer => maps:get(observer, Config, undefined)}};
        Error -> Error
    end;
new(_Config) ->
    {error, invalid_policy}.

authorize(#{mode := sleep}, Identity, Action, Resource) ->
    timer:sleep(250),
    delegate(Identity, Action, Resource);
authorize(#{mode := crash}, _Identity, _Action, _Resource) ->
    erlang:error(authorizer_crashed);
authorize(#{mode := heap}, Identity, Action, Resource) ->
    Heap = lists:seq(1, 1000000),
    put(authorizer_heap_fixture, Heap),
    delegate(Identity, Action, Resource);
authorize(#{mode := concurrent, observer := Observer, policy := Policy},
          Identity, Action, Resource) when is_pid(Observer) ->
    Observer ! {authorizer_entered, self()},
    receive
        {release_authorizer, Observer} ->
            adk_scope_authorizer:authorize(
              Policy, Identity, Action, Resource)
    after 2000 ->
        {error, forbidden}
    end;
authorize(#{policy := Policy}, Identity, Action, Resource) ->
    adk_scope_authorizer:authorize(Policy, Identity, Action, Resource).

delegate(Identity, Action, Resource) ->
    %% The failure modes never need to return an allow decision. Keeping this
    %% branch valid makes the fixture safe if a resource limit is accidentally
    %% relaxed during a regression.
    {ok, Policy} = adk_scope_authorizer:new(
                     #{trusted_issuers => [<<"https://identity.example.test">>],
                       required_scopes =>
                           #{list_agents => [<<"adk.agents.read">>],
                             start_run => [<<"adk.run.start">>],
                             observe_run => [<<"adk.run.read">>],
                             control_run => [<<"adk.run.control">>],
                             resume_run => [<<"adk.run.control">>]}}),
    adk_scope_authorizer:authorize(Policy, Identity, Action, Resource).
