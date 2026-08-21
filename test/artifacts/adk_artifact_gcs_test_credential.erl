-module(adk_artifact_gcs_test_credential).

-export([access_token/1]).

access_token(#{token := Token}) -> {ok, Token};
access_token(#{error := Error}) -> {error, Error};
access_token(_Handle) -> {error, unavailable}.
