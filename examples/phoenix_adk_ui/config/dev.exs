import Config

config :erlang_adk_ui, ErlangAdkUiWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}],
  check_origin: true,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "RUE5OPNW4BDjTN8YAMyPC0+NbQKM4SwPoS4h64nlFylHW7DsdX/S8UcCYaOCn3e+",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:erlang_adk_ui, ~w(--sourcemap=inline --watch)]}
  ],
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/.*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"lib/erlang_adk_ui_web/(controllers|live|components)/.*\.(ex|heex)$"E,
      ~r"lib/erlang_adk_ui_web/(endpoint|router)\.ex$"E
    ]
  ]

config :logger, :default_formatter, format: "[$level] $message\n"
config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true,
  enable_expensive_runtime_checks: true
