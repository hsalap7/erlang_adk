-module(adk_memory_embedding_test_provider).
-behaviour(adk_memory_embedding_provider).

-export([capabilities/1, embed/4]).

capabilities(_State) -> #{dimensions => 3, batch => true}.

embed(#{mode := good}, Model, Inputs, _Options) ->
    Vectors = [[float(byte_size(Input)), 1.0, 0.5] || Input <- Inputs],
    {ok, #{model => Model, dimensions => 3, vectors => Vectors,
           usage => #{inputs => length(Inputs)}}};
embed(#{mode := bad_shape}, Model, _Inputs, _Options) ->
    {ok, #{model => Model, dimensions => 2, vectors => [[1.0]],
           usage => #{}}};
embed(#{mode := secret_usage}, Model, Inputs, _Options) ->
    Vectors = [[1.0, 0.0, 0.0] || _ <- Inputs],
    {ok, #{model => Model, dimensions => 3, vectors => Vectors,
           usage => #{password => <<"usage-secret">>, inputs => 1}}};
embed(#{mode := wrong_model}, _Model, Inputs, _Options) ->
    Vectors = [[1.0, 0.0, 0.0] || _ <- Inputs],
    {ok, #{model => <<"different-model">>, dimensions => 3,
           vectors => Vectors, usage => #{}}};
embed(#{mode := secret_error}, _Model, _Inputs, _Options) ->
    {error, {authorization, <<"Bearer do-not-leak">>}};
embed(#{mode := hang}, _Model, _Inputs, _Options) ->
    receive stop -> ok after 5000 -> ok end,
    {error, late}.
