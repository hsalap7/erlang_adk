%% @doc Safe, registry-only descriptor for a connector instance.
%%
%% Agent configuration selects the resulting trusted toolset by registry ID.
%% This descriptor is operator-owned and contains only stable registry IDs; it
%% deliberately has no field for URLs, headers, tokens, passwords, or keys.
-module(adk_connector_descriptor).

-export([validate/2, describe/1]).

-define(MAX_ID_BYTES, 128).

-type service_kind() :: native | mcp | openapi.
-type registry_ref() :: #{kind := service_kind() | credential, id := binary()}.
-type descriptor() :: #{
    connector_id := binary(),
    service_ref := registry_ref(),
    credential_ref := registry_ref() | none
}.
-export_type([descriptor/0, registry_ref/0, service_kind/0]).

-spec validate(term(), service_kind()) ->
    {ok, descriptor()} | {error, term()}.
validate(Descriptor, ExpectedService) when is_map(Descriptor) ->
    Allowed = [connector_id, service_ref, credential_ref],
    case exact_keys(Descriptor, Allowed) of
        false -> {error, invalid_connector_descriptor_keys};
        true -> validate_fields(Descriptor, ExpectedService)
    end;
validate(_Descriptor, _ExpectedService) ->
    {error, invalid_connector_descriptor}.

validate_fields(#{connector_id := ConnectorId,
                  service_ref := ServiceRef,
                  credential_ref := CredentialRef}, ExpectedService) ->
    case {valid_service(ExpectedService),
          valid_id(ConnectorId),
          validate_ref(ServiceRef, ExpectedService),
          validate_credential_ref(CredentialRef)} of
        {true, true, {ok, CanonicalService}, {ok, CanonicalCredential}} ->
            {ok, #{connector_id => ConnectorId,
                   service_ref => CanonicalService,
                   credential_ref => CanonicalCredential}};
        {false, _, _, _} -> {error, invalid_connector_service};
        {_, false, _, _} -> {error, invalid_connector_id};
        {_, _, {error, _} = Error, _} -> Error;
        {_, _, _, {error, _} = Error} -> Error
    end;
validate_fields(_Descriptor, _ExpectedService) ->
    {error, incomplete_connector_descriptor}.

validate_ref(#{kind := Kind, id := Id} = Ref, ExpectedKind) ->
    case exact_keys(Ref, [kind, id]) andalso
         Kind =:= ExpectedKind andalso valid_id(Id) of
        true -> {ok, #{kind => Kind, id => Id}};
        false -> {error, invalid_connector_service_ref}
    end;
validate_ref(_Ref, _ExpectedKind) ->
    {error, invalid_connector_service_ref}.

validate_credential_ref(none) -> {ok, none};
validate_credential_ref(#{kind := credential, id := Id} = Ref) ->
    case exact_keys(Ref, [kind, id]) andalso valid_id(Id) of
        true -> {ok, #{kind => credential, id => Id}};
        false -> {error, invalid_connector_credential_ref}
    end;
validate_credential_ref(_Ref) ->
    {error, invalid_connector_credential_ref}.

-spec describe(descriptor()) -> map().
describe(#{connector_id := ConnectorId,
           service_ref := #{kind := ServiceKind, id := ServiceId},
           credential_ref := CredentialRef}) ->
    #{<<"connector_id">> => ConnectorId,
      <<"service_ref">> =>
          #{<<"kind">> => atom_to_binary(ServiceKind, utf8),
            <<"id">> => ServiceId},
      <<"credential_ref">> => describe_credential(CredentialRef)};
describe(_Descriptor) ->
    #{<<"status">> => <<"invalid">>}.

describe_credential(none) -> null;
describe_credential(#{kind := credential, id := Id}) ->
    #{<<"kind">> => <<"credential">>, <<"id">> => Id}.

valid_service(native) -> true;
valid_service(mcp) -> true;
valid_service(openapi) -> true;
valid_service(_) -> false.

valid_id(Id) when is_binary(Id), byte_size(Id) > 0,
                           byte_size(Id) =< ?MAX_ID_BYTES ->
    case binary:bin_to_list(Id) of
        [First | Rest] -> valid_first(First) andalso
                          lists:all(fun valid_rest/1, Rest);
        [] -> false
    end;
valid_id(_Id) -> false.

valid_first(C) ->
    (C >= $a andalso C =< $z) orelse
    (C >= $A andalso C =< $Z) orelse
    (C >= $0 andalso C =< $9).

valid_rest(C) ->
    valid_first(C) orelse C =:= $. orelse C =:= $_ orelse C =:= $-.

exact_keys(Map, Allowed) ->
    lists:sort(maps:keys(Map)) =:= lists:sort(Allowed).
