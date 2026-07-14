defmodule ErlangAdkUi.Auth.Provider do
  @moduledoc "Authentication provider contract used by the Phoenix boundary."

  @type flow :: map()
  @type identity :: %{
          required(:principal) => binary(),
          required(:subject) => binary(),
          required(:issuer) => binary(),
          required(:audiences) => [binary()],
          required(:scopes) => [binary()]
        }

  @callback authorization_request() ::
              {:ok, redirect_uri :: binary(), flow()} | {:error, :provider_unavailable}
  @callback complete(map(), flow()) ::
              {:ok, identity()} | {:error, :authentication_failed | :provider_unavailable}
end
