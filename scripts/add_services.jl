using PowerSystems
const PSY = PowerSystems
using Logging
using Dates
using DataFrames
using CSV

system = System("DA_sys.json")

include("file_pointers.jl")
include("system_build_functions.jl")
include("manual_data_entries.jl")

regup_reserve = CSV.read(reg_up_reserve, DataFrame)
regdn_reserve = CSV.read(reg_dn_reserve, DataFrame)
spin = CSV.read(spin_reserve, DataFrame)
nonspin = CSV.read(nonspin_reserve, DataFrame)

date_range = range(DateTime("2018-01-01T00:00:00"), step = Hour(1), length = 8796)

regup_reserve_ts = Vector{Float64}(undef, 8796)
regdn_reserve_ts = Vector{Float64}(undef, 8796)
spin_ts = Vector{Float64}(undef, 8796)
nonspin_ts = Vector{Float64}(undef, 8796)

for (ix, datetime) in enumerate(date_range)
    regup_reserve_ts[ix] = regup_reserve[hour(datetime) + 1, month(datetime) + 1]
    regdn_reserve_ts[ix] = regdn_reserve[hour(datetime) + 1, month(datetime) + 1]
    spin_ts[ix] = spin[hour(datetime) + 1, month(datetime) + 1]
    nonspin_ts[ix] = nonspin[hour(datetime) + 1, month(datetime) + 1]
end

plant_metadata = CSV.read(thermal_mapping, DataFrame)
sced_names = unique(plant_metadata.GeneratorID)
sced_names = [n for n in sced_names if n ∉ ["SAME", "STORAGE"]]
names_map = Dict(sced_names .=> "aa")
for name in sced_names
    name_ = plant_metadata[plant_metadata.GeneratorID .== name, :]."Plant Name"[1]
    gen_name = uppercase(replace(name_, " " => "_"))
    if get_component(ThermalMultiStart, system, gen_name) === nothing
        println(name, " ", gen_name)
    else
       names_map[name] = gen_name
    end
end

reg_dict = Dict{String, NamedTuple}()
spin_dict = Dict{String, Tuple}()
nonspin_dict = Dict{String, Tuple}()
for nemonic_name in sced_names
    try
        sced_data = get_sced_data(thermal_sced_h5_file, nemonic_name)
        sced_data_reg = sced_data[occursin.("ONREG", sced_data."Telemetered_Resource_Status"), :]
        total_points = isempty(sced_data_reg) ? 0.01 : length(sced_data.Ancillary_Service_REGUP)
        regup_points = isempty(sced_data_reg) ? 0.0 : sum(.!isapprox.(sced_data.Ancillary_Service_REGUP, 0.0))
        regdown_points = isempty(sced_data_reg) ? 0.0 : sum(.!isapprox.(sced_data.Ancillary_Service_REGDN, 0.0))

        participation_dn = regdown_points/total_points
        participation_up = regup_points/total_points
        reg_dict[nemonic_name] = (down = participation_dn, up = participation_up)

        sced_data_on = sced_data[occursin.(r"ON", sced_data."Telemetered_Resource_Status"), :]
        sced_data_on_reg = sced_data_on[occursin.(r"ONREG", sced_data_on."Telemetered_Resource_Status"), :]
        sced_data_on_nonreg = sced_data_on[.!occursin.(r"ONREG", sced_data_on."Telemetered_Resource_Status"), :]

        spin_times = sum(.!isapprox.(sced_data_on.Ancillary_Service_RRS, 0.0))
        spin_times_reg = sum(.!isapprox.(sced_data_on_reg.Ancillary_Service_RRS, 0.0))
        spin_times_nonreg = sum(.!isapprox.(sced_data_on_nonreg.Ancillary_Service_RRS, 0.0))
        spin_dict[nemonic_name] = (spin_times/(length(sced_data_on.Ancillary_Service_RRS) + 0.01),
                                spin_times_reg/(length(sced_data.Ancillary_Service_RRS) + .01),
                                spin_times_nonreg/(length(sced_data.Ancillary_Service_RRS) + 0.01),
                                   )
        sced_data_off = sced_data[occursin.(r"OFF", sced_data."Telemetered_Resource_Status", ), :]
        if isempty(sced_data_off)
            nonspin_dict[nemonic_name] = (0.0, 0.0)
        else
            nonspin_times = sum(.!isapprox.(sced_data_off.Ancillary_Service_NSRS, 0.0))
            nonspin_times_ = sum(.!isapprox.(sced_data.Ancillary_Service_NSRS, 0.0))
            nonspin_dict[nemonic_name] = (nonspin_times/length(sced_data_off.Ancillary_Service_NSRS), nonspin_times_/length(sced_data.Ancillary_Service_NSRS))
        end
    catch e
        @error e
        println(nemonic_name)
        continue
    end
end

non_spin_names = [k for (k, v) in nonspin_dict if v[1] > 0.0]
reg_down_names = [k for (k, v) in reg_dict if v.down > 0.2]
reg_up_names = [k for (k, v) in reg_dict if v.up > 0.2]
spin_names = [k for (k, v) in spin_dict if v[3] > 0 && k ∉ reg_up_names]

reserve_map = Dict(
    ("REG_UP", VariableReserve{ReserveUp}, reg_up_names) =>  regup_reserve_ts,
    ("SPIN", VariableReserve{ReserveUp}, spin_names) => spin_ts,
    ("REG_DN", VariableReserve{ReserveDown}, reg_down_names) => regdn_reserve_ts,
    ("NONSPIN", VariableReserveNonSpinning, non_spin_names) => nonspin_ts
)

for ((name, T, gens), ts) in reserve_map
    peak = maximum(ts)
    day_ahead_forecast = Dict{Dates.DateTime, Vector{Float64}}()
    for ix in 1:day_count
        current_ix = ix + (da_interval.value - 1)*(ix - 1)
        forecast = regup_reserve_ts[current_ix:(current_ix + da_horizon -1)]
        @assert !all(isnan.(forecast))
        @assert length(forecast) == da_horizon
        day_ahead_forecast[initial_time + (ix - 1)*da_interval] = forecast./peak
    end
    forecast_data = Deterministic(
                    name = "requirement",
                    resolution = Hour(1),
                    data = day_ahead_forecast)
    res = T(nothing)
    set_name!(res, name)
    set_requirement!(res, peak/100.0)
    set_available!(res, true)
    gen_names = [v for (k, v) in names_map if k ∈ gens]
    components = get_components(ThermalMultiStart, system, x -> get_name(x) ∈ gen_names)
    add_service!(system, res, components)
    add_time_series!(system,
                res,
                forecast_data
                )
    @assert length(get_contributing_devices(system, res)) == length(gens)
end

to_json(system, "intermediate_sys.json"; force = true)