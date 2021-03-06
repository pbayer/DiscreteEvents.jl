#
# This file is part of the DiscreteEvents.jl Julia package, MIT license
#
# Paul Bayer, 2020
#
# This is a Julia package for discrete event simulation
#
# this implements the event handling
#

# Return the next scheduled event.
_nextevent(c::Clock) = DataStructures.peek(c.sc.events)[1]

# Return the internal time (unitless) of next scheduled event.
_nextevtime(c::Clock) = DataStructures.peek(c.sc.events)[2]

# wait until all registered channels are empty
function _waitchannels(c::Clock)
    while any(ch->!isempty(ch), c.channels)
        yield()
    end
end

# Execute or evaluate the next timed event on a clock c.
@inline function _event!(c::Clock)
    _waitchannels(c)
    ev = dequeue!(c.sc.events)
    c.time = ev.t
    _evaluate(ev.ex)
    c.evcount += 1

    if (ev.Δt !== nothing) && (ev.n > 1) 
        ev.Δt isa Float64 && event!(c, ev.ex, c.time + ev.Δt, ev.Δt, n=ev.n-1)
        ev.Δt isa Distribution && event!(c, ev.ex, c.time + rand(ev.Δt), ev.Δt, n=ev.n-1)
    end
end

# First execute all sampling expressions in a schedule, then evaluate all
# conditional events and if conditions are met, execute them.
function _tick!(c::Clock)
    c.time = c.tn
    foreach(x -> _evaluate(x.ex), c.sc.samples)  # exec sampling
    # then lookup conditional events
    ix = findfirst(x->all(_evaluate(x.cond)), c.sc.cevents)
    while ix !== nothing
        _evaluate(splice!(c.sc.cevents, ix).ex)
        isempty(c.sc.cevents) && break
        ix = findfirst(x->all(_evaluate(x.cond)), c.sc.cevents)
    end
    c.scount +=1
end

_sampling(c::Clock) = !isempty(c.sc.samples) || !isempty(c.sc.cevents)

# ------------------------------------------------------
# step forward to next tick or scheduled event. At a tick evaluate
# 1) all sampling functions or expressions,
# 2) all conditional events, then
# 3) if an event is encountered, trigger the event.
# ------------------------------------------------------
# If sampling rate Δt==0, c.tn is set to 0
# If no events are present, c.tev is set to c.end_time
# -------------------------------------------------------
@inline function _step!(c::Clock)
    c.state = Busy()
    if !isempty(c.sc.events)
        c.tev ≤ c.time && (c.tev = _nextevtime(c))
        if _sampling(c)
            if c.tn <= c.tev     # if t_next_tick  ≤ t_next_event
                _tick!(c)
                if c.tn == c.tev # an event is scheduled at the same time
                    _event!(c)
                end
                c.tn += c.Δt
            else
                _event!(c)
            end
        else
            _event!(c)
        end
    elseif _sampling(c)
        _tick!(c)
        c.tn += c.Δt
    else
        (c.state == Busy()) && (c.state = Idle())
        return 99
        # error("_step!: nothing to evaluate")
    end
    # for i ∈ 1:10   # brute fix of clock overrunnig other tasks
    #     isempty(c.sc.events) ? yield() : break
    # end
    _waitchannels(c)
    !isempty(c.processes) && yield() # let processes run
    c.tev = !isempty(c.sc.events) ? _nextevtime(c) : c.end_time
    (c.state == Busy()) && (c.state = Idle())
    return 0
end

# ----------------------------------------------------
# execute all events in a clock cycle, then do the periodic actions
# ----------------------------------------------------
function _cycle!(clk::Clock, Δt::Float64, sync::Bool=false)
    clk.state = Busy()
    tcyc = clk.time + Δt
    clk.tev = length(clk.sc.events) ≥ 1 ? _nextevtime(clk) : clk.time
    while clk.time ≤ tcyc
        if (clk.tev ≤ tcyc) && length(clk.sc.events) ≥ 1
            _event!(clk)
        else
            clk.time = tcyc
            break
        end
        length(clk.processes) == 0 || yield() # let processes run
    end
    if !sync
        clk.tn = tcyc
        _tick!(clk)
    end
    (clk.state == Busy()) && (clk.state = Idle())
end
