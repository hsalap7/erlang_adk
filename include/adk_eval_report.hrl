%% Evaluation results are validated against the same 16 MiB external-term
%% boundary before persistence. Report producers and consumers must share a
%% single ceiling so a valid stored result cannot be accepted by one surface
%% and rejected by another solely because of transport defaults.
-define(ADK_EVAL_REPORT_MAX_BYTES, 16777216).
