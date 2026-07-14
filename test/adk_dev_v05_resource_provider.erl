-module(adk_dev_v05_resource_provider).

-export([resolve/3, capabilities/1,
         list_names/3, list_versions/4, delete/5,
         search/4, delete_entry/3, delete_session/3, delete_user/2]).

resolve(#{app := App, user := User, session := Session,
          artifact := ArtifactRef},
        artifact, {session, App, User, Session}) ->
    {ok, ArtifactRef};
resolve(#{app := App, user := User, memory := MemoryRef},
        memory, {user, App, User}) ->
    {ok, MemoryRef};
resolve(_Config, _Kind, _Scope) ->
    {error, forbidden}.

%% Deliberately scope-violating diagnostic service used to prove that the
%% developer boundary validates returned records instead of trusting an
%% application-owned resource provider to relabel them.
capabilities(_Handle) ->
    #{contract_version => 2, api_version => 1}.

list_names(#{artifact_scope := ReturnedScope}, _RequestedScope, _Options) ->
    {ok, #{scope => ReturnedScope, items => [<<"leaked.txt">>],
           next_cursor => undefined}}.

list_versions(#{artifact_scope := ReturnedScope}, _RequestedScope,
              <<"leaked.txt">>, _Options) ->
    {ok, #{items =>
               [#{scope => ReturnedScope,
                  name => <<"leaked.txt">>, version => 1,
                  mime_type => <<"text/plain">>, digest => <<"00">>,
                  size => 6, created_at => 1, metadata => #{}}],
           next_cursor => undefined}}.

delete(_Handle, _Scope, _Name, _Selector, _CallOptions) -> ok.

search(#{memory_scope := ReturnedScope}, _RequestedScope, _Query, _Options) ->
    {ok, [#{scope => ReturnedScope, id => <<"leaked-memory">>,
            content => <<"leaked content">>, score => 1.0,
            score_type => lexical_overlap, timestamp => 1,
            provenance => #{}}]}.

delete_entry(_Handle, _Scope, _Id) -> ok.
delete_session(_Handle, _Scope, _SessionId) -> ok.
delete_user(_Handle, _Scope) -> ok.
