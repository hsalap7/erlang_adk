defmodule ErlangAdkUiWeb.ErrorJSON do
  def render(template, _assigns) do
    status = Phoenix.Controller.status_message_from_template(template)
    %{errors: %{detail: status}}
  end
end
