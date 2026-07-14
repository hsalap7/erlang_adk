-module(adk_resolved_module_toolset).

-export([schemas/1, resolved_call/4]).

schemas({module, Module}) when is_atom(Module) ->
    [Module:schema()].

resolved_call({module, Module}, Name, Args, _Context)
  when is_atom(Module), is_binary(Name), is_map(Args) ->
    Schema = Module:schema(),
    case maps:get(<<"name">>, Schema, undefined) of
        Name ->
            {ok, #{name => Name,
                   args => Args,
                   module => Module,
                   parallel_safe => false,
                   pause_capable => false}};
        _ ->
            {error, unknown_tool}
    end;
resolved_call(_Handle, _Name, _Args, _Context) ->
    {error, unknown_tool}.
