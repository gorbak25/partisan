#!/usr/bin/env escript

%% TODO: Store results in ETS table.
%% TODO: Sort omissions ascending by size.
%% TODO: If we have a fail result for a prefix, fail result should propagate forward to bigger 
%%       sets of traces: dynamic partial order reduction.
%% TODO: All subsequent messages, after omitted messages, need to be removed from trace
%%       (optional delivery, not reified in the trace.)

main([TraceFile, ReplayTraceFile, CounterexampleConsultFile, RebarCounterexampleConsultFile, PreloadOmissionFile]) ->
    %% Open ets table.
    ?MODULE = ets:new(?MODULE, [named_table, set]),

    %% Open the trace file.
    {ok, TraceLines} = file:consult(TraceFile),

    %% Open the counterexample consult file:
    %% - we make an assumption that there will only be a single counterexample here.
    {ok, [{TestModule, TestFunction, [TestCommands]}]} = file:consult(CounterexampleConsultFile),

    io:format("Loading commands...~n", []),
    [io:format(" ~p.~n", [TestCommand]) || TestCommand <- TestCommands],

    %% Drop last command -- forced failure.
    TestFinalCommands = lists:reverse(tl(lists:reverse(TestCommands))),

    io:format("Rewritten commands...~n", []),
    [io:format(" ~p.~n", [TestFinalCommand]) || TestFinalCommand <- TestFinalCommands],

    %% Write the schedule out.
    {ok, CounterexampleIo} = file:open(RebarCounterexampleConsultFile, [write, {encoding, utf8}]),
    io:format(CounterexampleIo, "~p.~n", [{TestModule, TestFunction, [TestFinalCommands]}]),
    ok = file:close(CounterexampleIo),

    %% Remove forced failure from the trace.
    TraceLinesWithoutFailure = lists:filter(fun(Command) ->
        case Command of 
            {_, {_, [forced_failure]}} ->
                io:format("Removing command from trace: ~p~n", [Command]),
                false;
            _ ->
                true
        end
    end, hd(TraceLines)),

    %% Filter the trace into message trace lines.
    MessageTraceLines = lists:filter(fun({Type, Message}) ->
        case Type =:= pre_interposition_fun of 
            true ->
                {_TracingNode, InterpositionType, _OriginNode, _MessagePayload} = Message,

                case InterpositionType of 
                    forward_message ->
                        true;
                    _ -> 
                        false
                end;
            false ->
                false
        end
    end, TraceLinesWithoutFailure),
    io:format("Number of items in message trace: ~p~n", [length(MessageTraceLines)]),

    %% Generate the powerset of tracelines.
    MessageTraceLinesPowerset = powerset(MessageTraceLines),
    io:format("Number of message sets in powerset: ~p~n", [length(MessageTraceLinesPowerset)]),

    %% Traces to iterate.
    TracesToIterate = lists:sublist(lists:reverse(MessageTraceLinesPowerset), 2),

    %% For each trace, write out the preload omission file.
    {_, AcceptableOmissions} = lists:foldl(fun(Omissions, {Iteration, ValidOmissions}) ->
        %% Write out a new omission file from the previously used trace.
        io:format("Writing out new preload omissions file!~n", []),
        {ok, PreloadOmissionIo} = file:open(PreloadOmissionFile, [write, {encoding, utf8}]),
        [io:format(PreloadOmissionIo, "~p.~n", [O]) || O <- [Omissions]],
        ok = file:close(PreloadOmissionIo),

        %% Generate a new trace.
        io:format("Generating new trace based on message omissions (~p omissions): ~n", 
                  [length(Omissions)]),

        {FinalTraceLines, _} = lists:foldl(fun({Type, Message} = Line, {FinalTrace0, AdditionalOmissions0}) ->
            case Type =:= pre_interposition_fun of 
                true ->
                    {TracingNode, InterpositionType, OriginNode, MessagePayload} = Message,

                    case InterpositionType of 
                        forward_message ->
                            case lists:member(Line, Omissions) of 
                                true ->
                                    io:format("-> Omitting trace message (forward_message): ~p~n", 
                                              [Line]),
                                    % %% TODO: HACK: HARDCODED.
                                    ReceiveOmission = {Type, {OriginNode, receive_message, TracingNode, {forward_message, lampson_2pc, MessagePayload}}},
                                    io:format("-> Adding to additional omissions corresponding (receive_message): ~p~n", 
                                              [ReceiveOmission]),
                                    {FinalTrace0, AdditionalOmissions0 ++ [ReceiveOmission]};
                                false ->
                                    {FinalTrace0 ++ [Line], AdditionalOmissions0}
                            end;
                        receive_message -> 
                            case lists:member(Line, AdditionalOmissions0) of 
                                true ->
                                    io:format("-> Omitting corresponding message (receive_message): ~p~n", [Line]),
                                    {FinalTrace0, AdditionalOmissions0 -- [Line]};
                                false ->
                                    {FinalTrace0 ++ [Line], AdditionalOmissions0}
                            end
                    end;
                false ->
                    {FinalTrace0 ++ [Line], AdditionalOmissions0}
            end
        end, {[], []}, TraceLinesWithoutFailure),

        % io:format("New trace: ~n", []),
        % [io:format("-> ~p.~n", [TraceLine]) || TraceLine <- [FinalTraceLines]],

        %% Write out replay trace.
        io:format("Writing out new replay trace file!~n", []),
        {ok, TraceIo} = file:open(ReplayTraceFile, [write, {encoding, utf8}]),
        [io:format(TraceIo, "~p.~n", [TraceLine]) || TraceLine <- [FinalTraceLines]],
        ok = file:close(TraceIo),

        %% Run the trace.
        Command = "SHRINKING=true REPLAY=true PRELOAD_OMISSIONS_FILE=" ++ PreloadOmissionFile ++ " REPLAY_TRACE_FILE=" ++ ReplayTraceFile ++ " TRACE_FILE=" ++ TraceFile ++ " ./rebar3 proper --retry | tee /tmp/partisan.output",
        io:format("Executing command for iteration ~p of ~p:", [Iteration, length(TracesToIterate)]),
        io:format(" ~p~n", [Command]),
        Output = os:cmd(Command),

        %% Store set of omissions as omissions that didn't invalidate the execution.
        UpdatedOmissions = case string:find(Output, "{postcondition,false}") of 
            nomatch ->
                %% This passed.
                io:format("Test passed, adding omissions to set of supporting omissions!~n", []),

                %% Insert result into the ETS table.
                true = ets:insert(?MODULE, {Iteration, {Omissions, true}}),

                %% Add omissiont to list of value omissions.
                ValidOmissions ++ [Omissions];
            _ ->
                %% This failed.
                io:format("Test FAILED!~n", []),

                %% Insert result into the ETS table.
                true = ets:insert(?MODULE, {Iteration, {Omissions, false}}),

                %% Do not add omissions into the valid omissions.
                ValidOmissions
        end,

        %% Increment iteration, update valid omission schedules.
        {Iteration + 1, UpdatedOmissions}
    end, {1, []}, TracesToIterate),

    io:format("Out of ~p traces, found ~p that supported the execution.~n", [length(TracesToIterate), length(AcceptableOmissions)]),

    ok.

%% @doc Generate the powerset of messages.
powerset([]) -> 
    [[]];

powerset([H|T]) -> 
    PT = powerset(T),
    [ [H|X] || X <- PT ] ++ PT.


    % %% Open the trace file.
    % {ok, TraceLines} = file:consult(TraceFile),

    % %% Write out a new replay trace from the last used trace.
    % {ok, TraceIo} = file:open(ReplayTraceFile, [write, {encoding, utf8}]),

    % %% Open the counterexample consult file:
    % %% - we make an assumption that there will only be a single counterexample here.
    % {ok, [{TestModule, TestFunction, [TestCommands]}]} = file:consult(CounterexampleConsultFile),

    % io:format("Loading commands...~n", []),
    % [io:format("~p.~n", [TestCommand]) || TestCommand <- TestCommands],

    % %% Find command to remove.
    % {_TestRemovedYet, TestRemovedCommand, TestAlteredCommands} = lists:foldr(fun(TestCommand, {RY, RC, AC}) ->
    %     case RY of 
    %         false ->
    %             case TestCommand of 
    %                 {set, _Var, {call, ?CRASH_MODULE, _Command, _Args}} ->
    %                     io:format("Removing the following command from the trace:~n", []),
    %                     io:format(" ~p~n", [TestCommand]),
    %                     {true, TestCommand, AC};
    %                 _ ->
    %                     {false, RC, [TestCommand] ++ AC}
    %             end;
    %         true ->
    %             {RY, RC, [TestCommand] ++ AC}
    %     end
    % end, {false, undefined, []}, TestCommands),

    % %% If we removed a partition resolution command, then we need to remove
    % %% the partition introduction itself.
    % {TestSecondRemovedCommand, TestFinalCommands} = case TestRemovedCommand of 
    %     {set, _Var, {call, ?CRASH_MODULE, end_receive_omission, Args}} ->
    %         io:format(" Found elimination of partition, looking for introduction call...~n", []),

    %         {_, SRC, FC} = lists:foldr(fun(TestCommand, {RY, RC, AC}) ->
    %             case RY of 
    %                 false ->
    %                     case TestCommand of 
    %                         {set, _Var1, {call, ?CRASH_MODULE, begin_receive_omission, Args}} ->
    %                             io:format(" Removing the ASSOCIATED command from the trace:~n", []),
    %                             io:format("  ~p~n", [TestCommand]),
    %                             {true, TestCommand, AC};
    %                         _ ->
    %                             {false, RC, [TestCommand] ++ AC}
    %                     end;
    %                 true ->
    %                     {RY, RC, [TestCommand] ++ AC}
    %             end
    %         end, {false, undefined, []}, TestAlteredCommands),
    %         {SRC, FC};
    %     {set, _Var, {call, ?CRASH_MODULE, end_send_omission, Args}} ->
    %         io:format(" Found elimination of partition, looking for introduction call...~n", []),

    %         {_, SRC, FC} = lists:foldr(fun(TestCommand, {RY, RC, AC}) ->
    %             case RY of 
    %                 false ->
    %                     case TestCommand of 
    %                         {set, _Var1, {call, ?CRASH_MODULE, begin_send_omission, Args}} ->
    %                             io:format(" Removing the ASSOCIATED command from the trace:~n", []),
    %                             io:format("  ~p~n", [TestCommand]),
    %                             {true, TestCommand, AC};
    %                         _ ->
    %                             {false, RC, [TestCommand] ++ AC}
    %                     end;
    %                 true ->
    %                     {RY, RC, [TestCommand] ++ AC}
    %             end
    %         end, {false, undefined, []}, TestAlteredCommands),
    %         {SRC, FC};
    %     _ ->
    %         {undefined, TestAlteredCommands}
    % end,

    % %% Create list of commands to remove from the trace schedule.
    % CommandsToRemoveFromTrace = 
    %     lists:flatmap(fun({set, _Var2, {call, ?CRASH_MODULE, Function, [Node|Rest]}}) ->
    %         [{exit_command, {Node, [Function] ++ Rest}},
    %          {enter_command, {Node, [Function] ++ Rest}}]
    %     end, lists:filter(fun(X) -> X =/= undefined end, [TestSecondRemovedCommand, TestRemovedCommand])),
    % io:format("To be removed from trace: ~n", []),
    % [io:format(" ~p.~n", [CommandToRemoveFromTrace]) || CommandToRemoveFromTrace <- CommandsToRemoveFromTrace],

    % %% Prune out commands from the trace.
    % {FinalTraceLines, []} = lists:foldr(fun(TraceLine, {FTL, TR}) ->
    %     case length(TR) > 0 of
    %         false ->
    %             {[TraceLine] ++ FTL, TR};
    %         true ->
    %             ToRemove = hd(TR),
    %             case TraceLine of 
    %                 ToRemove ->
    %                     {FTL, tl(TR)};
    %                 _ ->
    %                     {[TraceLine] ++ FTL, TR}
    %             end
    %     end
    % end, {[], CommandsToRemoveFromTrace}, hd(TraceLines)),

    % %% Write the schedule out.
    % {ok, CounterexampleIo} = file:open(RebarCounterexampleConsultFile, [write, {encoding, utf8}]),
    % io:format(CounterexampleIo, "~p.~n", [{TestModule, TestFunction, [TestFinalCommands]}]),
    % ok = file:close(CounterexampleIo),

    % %% Write new trace out.
    % [io:format(TraceIo, "~p.~n", [TraceLine]) || TraceLine <- [FinalTraceLines]],
    % ok = file:close(TraceIo),

    % % %% Print out final schedule.
    % % %% lists:foreach(fun(Command) -> io:format("~p~n", [Command]) end, AlteredCommands),

    % ok.