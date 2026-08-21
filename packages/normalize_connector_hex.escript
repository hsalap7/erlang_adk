#!/usr/bin/env escript
%%! -noshell
%%
%% Rebuild a connector Hex tarball with dependency metadata taken directly
%% from the package's rebar.config. rebar3_hex intentionally derives package
%% requirements from rebar.lock; a local _checkouts/erlang_adk used by the
%% source-tree tests is omitted from that lock and would otherwise produce a
%% tarball with an empty requirements map.

-mode(compile).

main([Tarball0]) ->
    try
        Tarball = filename:absname(Tarball0),
        add_hex_core_path(),
        {App, Version, Requirements} = package_contract(),
        rebuild(Tarball, App, Version, Requirements)
    catch
        Class:Reason:Stacktrace ->
            io:format(standard_error,
                      "connector Hex normalization failed: ~tp:~tp~n~tp~n",
                      [Class, Reason, Stacktrace]),
            halt(1)
    end;
main(_) ->
    io:format(standard_error,
              "usage: escript ../normalize_connector_hex.escript "
              "PATH_TO_PACKAGE_TAR~n", []),
    halt(64).

add_hex_core_path() ->
    case filelib:wildcard("_build/*/plugins/hex_core/ebin") of
        [Path | _] ->
            true = code:add_patha(filename:absname(Path)),
            ok;
        [] ->
            error(hex_core_not_built)
    end.

package_contract() ->
    {ok, Config} = file:consult("rebar.config"),
    Dependencies = proplists:get_value(deps, Config, []),
    Requirements = requirements(Dependencies),
    #{<<"erlang_adk">> :=
          #{<<"requirement">> := CoreRequirement}} = Requirements,
    [AppSource] = filelib:wildcard("src/*.app.src"),
    {ok, [{application, App, AppProperties}]} = file:consult(AppSource),
    true = App =/= erlang_adk,
    Applications = proplists:get_value(applications, AppProperties, []),
    true = lists:member(erlang_adk, Applications),
    Version = list_to_binary(proplists:get_value(vsn, AppProperties)),
    ExpectedCoreRequirement = <<"~> ", Version/binary>>,
    ExpectedCoreRequirement = CoreRequirement,
    {atom_to_binary(App, utf8), Version, Requirements}.

requirements(Dependencies) ->
    maps:from_list([requirement(Dependency) || Dependency <- Dependencies]).

requirement({Application, Requirement0})
  when is_atom(Application),
       (is_list(Requirement0) orelse is_binary(Requirement0)) ->
    Name = atom_to_binary(Application, utf8),
    Requirement = iolist_to_binary(Requirement0),
    {Name,
     #{<<"app">> => Name,
       <<"optional">> => false,
       <<"requirement">> => Requirement}};
requirement(Unsupported) ->
    error({unsupported_hex_dependency, Unsupported}).

rebuild(TarballPath, App, Version, Requirements) ->
    {ok, Tarball0} = file:read_file(TarballPath),
    {ok, #{metadata := Metadata0, contents := Contents}} =
        hex_tarball:unpack(Tarball0, memory),
    ok = reject_checkout_leakage(Metadata0, Contents),
    App = maps:get(<<"app">>, Metadata0),
    App = maps:get(<<"name">>, Metadata0),
    Version = maps:get(<<"version">>, Metadata0),
    ExistingRequirements = maps:get(<<"requirements">>, Metadata0, #{}),
    ok = compatible_requirements(ExistingRequirements, Requirements),
    Metadata = Metadata0#{<<"requirements">> => Requirements},
    {ok, #{tarball := Tarball,
           outer_checksum := OuterChecksum}} =
        hex_tarball:create(Metadata, Contents),
    TempPath = TarballPath ++ ".requirements.tmp",
    ok = file:write_file(TempPath, Tarball),
    ok = file:rename(TempPath, TarballPath),
    {ok, #{metadata := #{<<"requirements">> := Requirements}}} =
        hex_tarball:unpack(Tarball, memory),
    io:format(
      "normalized ~ts ~ts: erlang_adk requirement=~ts optional=false "
      "sha256=~ts~n",
      [App, Version, core_requirement(Requirements),
       hex_tarball:format_checksum(OuterChecksum)]).

core_requirement(
  #{<<"erlang_adk">> := #{<<"requirement">> := Requirement}}) ->
    Requirement.

reject_checkout_leakage(Metadata, Contents) ->
    DeclaredFiles = maps:get(<<"files">>, Metadata, []),
    Paths = [unicode:characters_to_list(Path) || Path <- DeclaredFiles] ++
            [Path || {Path, _Data} <- Contents],
    case [Path || Path <- Paths, checkout_path(Path)] of
        [] -> ok;
        Leaked -> error({checkout_paths_in_hex_archive, Leaked})
    end.

checkout_path("_checkouts") -> true;
checkout_path("_checkouts/" ++ _Rest) -> true;
checkout_path(Path) ->
    string:find(Path, "/_checkouts/") =/= nomatch.

compatible_requirements(Requirements, Requirements) ->
    ok;
compatible_requirements(Existing, _Expected) when map_size(Existing) =:= 0 ->
    ok;
compatible_requirements(Existing, Expected) ->
    error({conflicting_hex_requirements, Existing, Expected}).
