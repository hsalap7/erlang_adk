%% @doc Render-first deployment command boundary for reviewed manifests.
%%
%% Dry-run validation is the default. Mutation requires `apply => true', an
%% immutable pre-rendered manifest, and the exact destination identity. No
%% shell is involved and command output is bounded and never returned on
%% failures, so credentials cannot be reflected through the CLI result.
-module(adk_deploy).

-export([cloud_run/1, gke/1]).

-define(MAX_MANIFEST_BYTES, 16777216).
-define(MAX_COMMAND_OUTPUT_BYTES, 1048576).
-define(COMMAND_TIMEOUT_MS, 120000).

-spec cloud_run(map()) -> {ok, map()} | {error, term()}.
cloud_run(Options) when is_map(Options) ->
    Allowed = [manifest, project, region, apply],
    case {maps:keys(maps:without(Allowed, Options)),
          checked_manifest(maps:get(manifest, Options, undefined), cloud_run),
          checked_text(maps:get(project, Options, undefined), project),
          checked_text(maps:get(region, Options, undefined), region),
          checked_apply(maps:get(apply, Options, false))} of
        {[], {ok, Manifest}, {ok, Project}, {ok, Region}, {ok, Apply}} ->
            Plan = (plan(cloud_run, Manifest))#{
                      project => Project, region => Region},
            maybe_apply_cloud_run(Apply, Manifest, Project, Region, Plan);
        {[_ | _] = Unknown, _, _, _, _} ->
            {error, {unknown_deploy_options, lists:sort(Unknown)}};
        {_, {error, _} = Error, _, _, _} -> Error;
        {_, _, {error, _} = Error, _, _} -> Error;
        {_, _, _, {error, _} = Error, _} -> Error;
        {_, _, _, _, {error, _} = Error} -> Error
    end;
cloud_run(_Options) -> {error, invalid_deploy_options}.

-spec gke(map()) -> {ok, map()} | {error, term()}.
gke(Options) when is_map(Options) ->
    Allowed = [manifest, context, namespace, apply],
    case {maps:keys(maps:without(Allowed, Options)),
          checked_manifest(maps:get(manifest, Options, undefined), gke),
          checked_text(maps:get(context, Options, undefined), context),
          checked_text(maps:get(namespace, Options, undefined), namespace),
          checked_apply(maps:get(apply, Options, false))} of
        {[], {ok, Manifest}, {ok, Context}, {ok, Namespace}, {ok, Apply}} ->
            Plan = (plan(gke, Manifest))#{
                      context => Context, namespace => Namespace},
            maybe_apply_gke(Apply, Manifest, Context, Namespace, Plan);
        {[_ | _] = Unknown, _, _, _, _} ->
            {error, {unknown_deploy_options, lists:sort(Unknown)}};
        {_, {error, _} = Error, _, _, _} -> Error;
        {_, _, {error, _} = Error, _, _} -> Error;
        {_, _, _, {error, _} = Error, _} -> Error;
        {_, _, _, _, {error, _} = Error} -> Error
    end;
gke(_Options) -> {error, invalid_deploy_options}.

plan(Target, #{path := Path, digest := Digest, bytes := Bytes}) ->
    #{target => Target, mode => validate_only, apply => false,
      manifest => Path, manifest_sha256 => Digest,
      manifest_bytes => Bytes,
      note => <<"No changes made; review the manifest and pass --apply">>}.

maybe_apply_cloud_run(false, _Manifest, _Project, _Region, Plan) ->
    {ok, Plan};
maybe_apply_cloud_run(true, Manifest, Project, Region, Plan) ->
    case executable("gcloud") of
        {ok, Executable} ->
            Args = ["run", "services", "replace",
                    path_string(Manifest), "--project", binary_to_list(Project),
                    "--region", binary_to_list(Region)],
            case run_command(Executable, Args, discard) of
                {ok, _} ->
                    {ok, Plan#{mode => applied, apply => true,
                               note => <<"Cloud Run service manifest applied">>}};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

maybe_apply_gke(false, _Manifest, _Context, _Namespace, Plan) ->
    {ok, Plan};
maybe_apply_gke(true, Manifest, Context, Namespace, Plan) ->
    case executable("kubectl") of
        {ok, Executable} ->
            case run_command(Executable, ["config", "current-context"], capture) of
                {ok, Current0} ->
                    Current = trim_ascii(Current0),
                    case Current =:= Context of
                        true ->
                            Args = ["--context", binary_to_list(Context),
                                    "--namespace", binary_to_list(Namespace),
                                    "apply", "-f", path_string(Manifest)],
                            case run_command(Executable, Args, discard) of
                                {ok, _} ->
                                    {ok, Plan#{mode => applied, apply => true,
                                               note => <<"GKE manifest applied">>}};
                                {error, _} = Error -> Error
                            end;
                        false -> {error, deployment_context_mismatch}
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

checked_manifest(undefined, _Target) -> {error, deployment_manifest_required};
checked_manifest(Path0, Target) ->
    case normalize_path(Path0) of
        {ok, Path} ->
            case adk_bounded_file:read(Path, ?MAX_MANIFEST_BYTES) of
                {ok, Body} when byte_size(Body) > 0 ->
                    case valid_manifest(Target, Body) of
                        true ->
                            Digest = binary:encode_hex(
                                       crypto:hash(sha256, Body), lowercase),
                            {ok, #{path => Path, digest => Digest,
                                   bytes => byte_size(Body)}};
                        false -> {error, invalid_deployment_manifest}
                    end;
                {ok, <<>>} -> {error, invalid_deployment_manifest};
                {error, Reason} -> {error, {deployment_manifest, Reason}}
            end;
        {error, _} = Error -> Error
    end.

normalize_path(Path) when is_binary(Path), byte_size(Path) > 0,
                               byte_size(Path) =< 4096 ->
    case valid_utf8(Path) andalso binary:match(Path, <<0>>) =:= nomatch of
        true -> {ok, Path};
        false -> {error, invalid_deployment_manifest_path}
    end;
normalize_path(Path) when is_list(Path) ->
    try normalize_path(unicode:characters_to_binary(Path))
    catch _:_ -> {error, invalid_deployment_manifest_path}
    end;
normalize_path(_) -> {error, invalid_deployment_manifest_path}.

valid_manifest(cloud_run, Body) ->
    binary:match(Body, <<"apiVersion: serving.knative.dev/v1">>) =/= nomatch
        andalso binary:match(Body, <<"kind: Service">>) =/= nomatch
        andalso binary:match(Body, <<0>>) =:= nomatch;
valid_manifest(gke, Body) ->
    binary:match(Body, <<"apiVersion:">>) =/= nomatch
        andalso binary:match(Body, <<"kind:">>) =/= nomatch
        andalso binary:match(Body, <<0>>) =:= nomatch.

checked_apply(Value) when is_boolean(Value) -> {ok, Value};
checked_apply(_) -> {error, invalid_deployment_apply_flag}.

checked_text(Value0, Kind) ->
    case normalize_text(Value0) of
        {ok, Value} ->
            case valid_text_kind(Kind, Value) of
                true -> {ok, Value};
                false -> {error, {invalid_deployment_target, Kind}}
            end;
        {error, _} -> {error, {invalid_deployment_target, Kind}}
    end.

normalize_text(Value) when is_binary(Value), byte_size(Value) > 0,
                           byte_size(Value) =< 256 ->
    case valid_utf8(Value) of
        true -> {ok, Value};
        false -> {error, invalid_text}
    end;
normalize_text(Value) when is_list(Value) ->
    try normalize_text(unicode:characters_to_binary(Value))
    catch _:_ -> {error, invalid_text}
    end;
normalize_text(_) -> {error, invalid_text}.

valid_text_kind(project, Value) ->
    valid_ascii(Value, fun project_char/1);
valid_text_kind(region, Value) ->
    valid_ascii(Value, fun lowercase_name_char/1);
valid_text_kind(context, Value) ->
    valid_ascii(Value, fun context_char/1);
valid_text_kind(namespace, Value) ->
    valid_ascii(Value, fun lowercase_name_char/1).

valid_ascii(Value, Predicate) ->
    lists:all(Predicate, binary_to_list(Value)).

project_char(C) ->
    ascii_alnum(C) orelse lists:member(C, ":._-").

lowercase_name_char(C) ->
    (C >= $a andalso C =< $z) orelse
        (C >= $0 andalso C =< $9) orelse C =:= $-.

context_char(C) ->
    ascii_alnum(C) orelse lists:member(C, ":._/@-").

ascii_alnum(C) ->
    (C >= $a andalso C =< $z) orelse
        (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9).

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch _:_ -> false
    end.

executable(Name) ->
    case os:find_executable(Name) of
        false -> {error, {deployment_executable_unavailable,
                          unicode:characters_to_binary(Name)}};
        Path -> {ok, Path}
    end.

path_string(#{path := Path}) when is_binary(Path) -> binary_to_list(Path).

run_command(Executable, Args, Mode) ->
    Options = [binary, exit_status, use_stdio, stderr_to_stdout,
               {args, Args}],
    try erlang:open_port({spawn_executable, Executable}, Options) of
        Port ->
            Deadline = erlang:monotonic_time(millisecond) +
                       ?COMMAND_TIMEOUT_MS,
            collect_command(Port, <<>>, Deadline, Mode)
    catch
        _:_ -> {error, deployment_command_start_failed}
    end.

collect_command(Port, Output, Deadline, Mode) ->
    Remaining = erlang:max(
                  0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} when is_binary(Data) ->
            case byte_size(Output) + byte_size(Data) =<
                 ?MAX_COMMAND_OUTPUT_BYTES of
                true ->
                    collect_command(
                      Port, <<Output/binary, Data/binary>>, Deadline, Mode);
                false ->
                    close_command(Port, deployment_command_output_limit)
            end;
        {Port, {exit_status, 0}} when Mode =:= capture -> {ok, Output};
        {Port, {exit_status, 0}} -> {ok, <<>>};
        {Port, {exit_status, Status}} ->
            {error, {deployment_command_failed, Status}}
    after Remaining ->
        close_command(Port, deployment_command_timeout)
    end.

close_command(Port, Reason) ->
    _ = catch erlang:port_close(Port),
    {error, Reason}.

trim_ascii(Binary) ->
    try string:trim(Binary) of
        Result when is_binary(Result) -> Result;
        _ -> <<>>
    catch _:_ -> <<>>
    end.
