-module(erlang_adk_postgres_test_backend).

-behaviour(erlang_adk_postgres_backend).

-export([execute_prepared/5]).

execute_prepared(Target, Mode, StatementId, Parameters, Descriptor) ->
    Target ! {postgres_executed, Mode, StatementId, Parameters, Descriptor},
    {ok, #{rows => []}}.
