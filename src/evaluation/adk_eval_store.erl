%% @doc Durable-storage contract for evaluation sets, jobs, results, and baselines.
%%
%% Stores are always scoped to an exact application.  Eval-set revisions are
%% immutable: writing the same canonical revision is idempotent, while trying
%% to replace it with different content fails.  Job transitions use an
%% expected-phase list so adapters can enforce lifecycle changes atomically.
-module(adk_eval_store).

-export([validate_scope/1, prepare_set/1, prepare_metadata/1,
         valid_job_id/1, valid_name/1, digest/1, public_job/1,
         terminal_phase/1]).

-export_type([handle/0, scope/0, phase/0, job/0]).

-type handle() :: term().
-type scope() :: {app, binary()}.
-type phase() :: queued | running | completed | failed | timed_out | cancelled.
-type job() :: map().

-callback ownership_identity(ConfigOrHandle :: term()) ->
    {ok, term()} | defer | {error, term()}.
-callback capabilities(Handle :: handle()) -> map().
-callback put_set(Handle :: handle(), Scope :: scope(), Set :: map()) ->
    {ok, map()} | {error, term()}.
-callback get_set(Handle :: handle(), Scope :: scope(), Id :: binary(),
                  Version :: binary()) ->
    {ok, map()} | {error, not_found | term()}.
-callback list_sets(Handle :: handle(), Scope :: scope(), Options :: map()) ->
    {ok, map()} | {error, term()}.
-callback create_job(Handle :: handle(), Scope :: scope(), Job :: job()) ->
    {ok, job()} | {error, already_exists | term()}.
-callback create_evaluation(Handle :: handle(), Scope :: scope(),
                            Set :: map(), Job :: job()) ->
    {ok, map()} | {error, term()}.
-callback transition_job(Handle :: handle(), Scope :: scope(),
                         JobId :: binary(), Expected :: [phase()],
                         Phase :: phase(), Patch :: map()) ->
    {ok, job()} | {error, not_found | stale_phase | term()}.
-callback get_job(Handle :: handle(), Scope :: scope(), JobId :: binary()) ->
    {ok, job()} | {error, not_found | term()}.
-callback list_jobs(Handle :: handle(), Scope :: scope(), Options :: map()) ->
    {ok, map()} | {error, term()}.
-callback put_baseline(Handle :: handle(), Scope :: scope(), Name :: binary(),
                       JobId :: binary()) ->
    {ok, map()} | {error, not_found | job_not_completed | term()}.
-callback get_baseline(Handle :: handle(), Scope :: scope(), Name :: binary()) ->
    {ok, map()} | {error, not_found | term()}.
-callback recover_active(Handle :: handle(), Reason :: binary()) ->
    {ok, non_neg_integer()} | {error, term()}.
-callback prune(Handle :: handle(), Scope :: scope(), Options :: map()) ->
    {ok, map()} | {error, term()}.

-define(MAX_ID_BYTES, 256).
-define(MAX_METADATA_BYTES, 1048576).

-spec validate_scope(term()) -> ok | {error, invalid_eval_scope}.
validate_scope({app, App}) when is_binary(App), byte_size(App) > 0,
                                byte_size(App) =< ?MAX_ID_BYTES ->
    case valid_utf8(App) of
        true -> ok;
        false -> {error, invalid_eval_scope}
    end;
validate_scope(_Scope) ->
    {error, invalid_eval_scope}.

-spec prepare_set(term()) ->
    {ok, map(), binary(), binary(), binary()} | {error, term()}.
prepare_set(Set0) when is_map(Set0) ->
    case adk_eval_set:validate(Set0) of
        {ok, Set} ->
            Id = maps:get(<<"id">>, Set),
            Version = maps:get(<<"version">>, Set),
            {ok, Set, Id, Version, digest(Set)};
        {error, _} = Error -> Error
    end;
prepare_set(_Set) ->
    {error, invalid_eval_set}.

-spec prepare_metadata(term()) -> {ok, map()} | {error, term()}.
prepare_metadata(Metadata0) when is_map(Metadata0) ->
    Limits = metadata_limits(),
    case adk_eval_limits:check(Metadata0, Limits) of
        ok ->
            Metadata1 = adk_secret_redactor:redact(Metadata0),
            case adk_json:normalize(Metadata1) of
                {ok, Metadata} when is_map(Metadata) ->
                    case adk_eval_limits:check(Metadata, Limits) of
                        ok -> {ok, Metadata};
                        {error, Reason} ->
                            {error, {invalid_eval_job_metadata, Reason}}
                    end;
                {ok, _} -> {error, invalid_eval_job_metadata};
                {error, Reason} ->
                    {error, {invalid_eval_job_metadata, Reason}}
            end;
        {error, Reason} ->
            {error, {invalid_eval_job_metadata, Reason}}
    end;
prepare_metadata(_Metadata) ->
    {error, invalid_eval_job_metadata}.

-spec valid_job_id(term()) -> boolean().
valid_job_id(Value) -> valid_name(Value).

-spec valid_name(term()) -> boolean().
valid_name(Value) when is_binary(Value), byte_size(Value) > 0,
                       byte_size(Value) =< ?MAX_ID_BYTES ->
    valid_utf8(Value);
valid_name(_Value) -> false.

-spec digest(term()) -> binary().
digest(Value) ->
    binary:encode_hex(
      crypto:hash(sha256, term_to_binary(Value, [deterministic])),
      lowercase).

-spec public_job(job()) -> job().
public_job(Job) when is_map(Job) ->
    maps:without([result, task_ref], Job).

-spec terminal_phase(term()) -> boolean().
terminal_phase(completed) -> true;
terminal_phase(failed) -> true;
terminal_phase(timed_out) -> true;
terminal_phase(cancelled) -> true;
terminal_phase(_) -> false.

metadata_limits() ->
    #{max_depth => 64, max_nodes => 50000,
      max_binary_bytes => ?MAX_METADATA_BYTES,
      max_total_binary_bytes => ?MAX_METADATA_BYTES,
      max_list_length => 10000, max_map_size => 10000,
      max_external_bytes => ?MAX_METADATA_BYTES}.

valid_utf8(Value) ->
    try unicode:characters_to_binary(Value, utf8, utf8) of
        Value -> true;
        _ -> false
    catch
        _:_ -> false
    end.
