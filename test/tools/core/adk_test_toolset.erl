-module(adk_test_toolset).

-export([schemas/1, resolved_call/4]).

schemas({counted, TestPid}) when is_pid(TestPid) ->
    TestPid ! toolset_schema_read,
    dynamic_echo_schemas();
schemas({duplicate, _TestPid}) ->
    [dynamic_echo_schema(), dynamic_echo_schema()];
schemas({invalid_schema, _TestPid}) ->
    [#{<<"name">> => <<"broken_dynamic_tool">>,
       <<"parameters">> => #{<<"type">> => <<"mystery">>}}];
schemas({mutable, CatalogPid, _TestPid}) when is_pid(CatalogPid) ->
    [dynamic_echo_schema(current_schema_name(CatalogPid))];
schemas({mutable_confirmation, CatalogPid, _TestPid, _Confirmation})
  when is_pid(CatalogPid) ->
    [dynamic_echo_schema(current_schema_name(CatalogPid))];
schemas({confirmation, _TestPid, _Confirmation}) ->
    dynamic_echo_schemas();
schemas({resolution_probe, _TestPid}) ->
    dynamic_echo_schemas();
schemas({resolved_module, _TestPid, _Module, _Confirmation}) ->
    dynamic_echo_schemas();
schemas(_Handle) ->
    dynamic_echo_schemas().

dynamic_echo_schemas() ->
    [dynamic_echo_schema()].

dynamic_echo_schema() ->
    dynamic_echo_schema(<<"dynamic_echo">>).

dynamic_echo_schema(Name) ->
    #{<<"name">> => Name,
      <<"description">> => <<"Echo through a resolved toolset call">>,
      <<"parameters">> =>
          #{<<"type">> => <<"object">>,
            <<"properties">> =>
                #{<<"text">> => #{<<"type">> => <<"string">>}},
            <<"required">> => [<<"text">>],
            <<"additionalProperties">> => false}}.

resolved_call(Handle, <<"dynamic_echo">>, Args, Context)
  when is_pid(Handle) ->
    resolved_echo_call(Handle, <<"dynamic_echo">>, Args, Context, undefined);
resolved_call({counted, TestPid}, <<"dynamic_echo">>, Args, Context)
  when is_pid(TestPid) ->
    resolved_echo_call(
      TestPid, <<"dynamic_echo">>, Args, Context, undefined);
resolved_call({confirmation, TestPid, Confirmation},
              <<"dynamic_echo">>, Args, Context)
  when is_pid(TestPid) ->
    resolved_echo_call(
      TestPid, <<"dynamic_echo">>, Args, Context, Confirmation);
resolved_call({resolution_probe, TestPid}, <<"dynamic_echo">>, Args, Context)
  when is_pid(TestPid) ->
    TestPid ! {dynamic_tool_resolved, Args, Context},
    resolved_echo_call(
      TestPid, <<"dynamic_echo">>, Args, Context, undefined);
resolved_call({resolved_module, TestPid, Module, Confirmation},
              <<"dynamic_echo">> = Name, Args, Context)
  when is_pid(TestPid), is_atom(Module) ->
    TestPid ! {resolved_module_resolved, Args, Context},
    Call = #{name => Name,
             args => Args,
             module => Module,
             parallel_safe => false,
             pause_capable => false,
             timeout => 1000},
    case Confirmation of
        undefined -> {ok, Call};
        _ -> {ok, Call#{confirmation => Confirmation}}
    end;
resolved_call({mutable, CatalogPid, TestPid}, Name, Args, Context)
  when is_pid(CatalogPid), is_pid(TestPid) ->
    case current_schema_name(CatalogPid) of
        Name -> resolved_echo_call(TestPid, Name, Args, Context, undefined);
        _CurrentName -> {error, unknown_tool}
    end;
resolved_call({mutable_confirmation, CatalogPid, TestPid, Confirmation},
              Name, Args, Context)
  when is_pid(CatalogPid), is_pid(TestPid) ->
    case current_schema_name(CatalogPid) of
        Name ->
            resolved_echo_call(TestPid, Name, Args, Context, Confirmation);
        _CurrentName ->
            {error, unknown_tool}
    end;
resolved_call(_Handle, _Name, _Args, _Context) ->
    {error, unknown_tool}.

resolved_echo_call(TestPid, Name, Args, Context, Confirmation) ->
    Execute = fun() ->
        TestPid ! {dynamic_tool_executed, self(), Args, Context},
        {ok, #{<<"echo">> => maps:get(<<"text">>, Args)}}
    end,
    Call = #{name => Name,
             args => Args,
             execute => Execute,
             parallel_safe => true,
             pause_capable => false,
             timeout => 1000},
    case Confirmation of
        undefined -> {ok, Call};
        _ -> {ok, Call#{confirmation => Confirmation}}
    end.

current_schema_name(CatalogPid) ->
    Ref = make_ref(),
    CatalogPid ! {get_catalog_name, self(), Ref},
    receive
        {catalog_name, Ref, Name} when is_binary(Name) -> Name
    after 1000 ->
        erlang:error(catalog_source_timeout)
    end.
