module core

import CSV
import DataFrames
import JLD
import JuMP
import GLPK
import Gurobi
import LinearAlgebra: transpose
import MAT
import SparseArrays: sparse


function read_case()
    print("reading")
    # Read case.mat
    case_mat_file = MAT.matopen("case.mat")
    mpc = read(case_mat_file, "mpc")
    
    # New case.mat analog
    case = Dict()
    
    # AC branches
    # dropdims() will remove extraneous dimension
    case["branchid"] = dropdims(mpc["branchid"], dims=2)
    # convert() will convert float array to int array
    case["branch_from"] = convert(Array{Int,1}, mpc["branch"][:,1])
    case["branch_to"] = convert(Array{Int,1}, mpc["branch"][:,2])
    case["branch_reactance"] = mpc["branch"][:,4]
    case["branch_rating"] = mpc["branch"][:,6]
    
    # DC branches
    if MAT.exists(case_mat_file, "dcline")
        case["dclineid"] = dropdims(mpc["dclineid"], dims=2)
        case["dcline_from"] = convert(Array{Int,1}, mpc["dcline"][:,1])
        case["dcline_to"] = convert(Array{Int,1}, mpc["dcline"][:,2])
        case["dcline_rating"] = mpc["dcline"][:,11]
    end
    
    # Buses
    case["busid"] = convert(Array{Int,1}, mpc["bus"][:,1])
    case["bus_demand"] = mpc["bus"][:,3]
    case["bus_zone"] = convert(Array{Int,1}, mpc["bus"][:,7])
    
    # Generators
    case["genid"] = dropdims(mpc["genid"], dims=2)
    genfuel = dropdims(mpc["genfuel"], dims=2)
    case["genfuel"] = convert(Array{String,1}, genfuel)
    case["gen_bus"] = convert(Array{Int,1}, mpc["gen"][:,1])
    case["gen_pmax"] = mpc["gen"][:,9]
    case["gen_pmin"] = mpc["gen"][:,10]
    case["gen_ramp30"] = mpc["gen"][:,19]
    
    # Generator costs
    case["gen_c2"] = mpc["gencost"][:,5]
    case["gen_c1"] = mpc["gencost"][:,6]
    case["gen_c0"] = mpc["gencost"][:,7]
    
    # Load all relevant profile data from CSV files
    case["demand"] = CSV.File("demand.csv") |> DataFrames.DataFrame
    case["hydro"] = CSV.File("hydro.csv") |> DataFrames.DataFrame
    case["wind"] = CSV.File("wind.csv") |> DataFrames.DataFrame
    case["solar"] = CSV.File("solar.csv") |> DataFrames.DataFrame
    
    return case
end


function reise_data_mods(case::Dict)
    # Modify PMINs
    case["gen_pmin"][case["genfuel"] .!= "coal"] .= 0
    nuclear_idx = case["genfuel"] .== "nuclear"
    case["gen_pmin"][nuclear_idx] = 0.95 * (case["gen_pmax"][nuclear_idx])
    geo_idx = case["genfuel"] .== "geothermal"
    case["gen_pmin"][geo_idx] = 0.95 * (case["gen_pmax"][geo_idx])
    
    # convert 'ax^2 + bx + c' to single-segment 'ax + b'
    case["gen_a_new"] = (
        case["gen_c2"] .* (case["gen_pmax"] .+ case["gen_pmin"])
        .+ case["gen_c1"])
    case["gen_b_new"] = (
        case["gen_c0"]
        .- case["gen_c2"] .* case["gen_pmax"] .* case["gen_pmin"])
    
    # Relax ramp constraints
    case["gen_ramp30"] .= Inf
    # Then set them based on capacity
    ramp30_points = Dict(
        "coal" => Dict("xs" => (200, 1400), "ys" => (0.4, 0.15)),
        "dfo" => Dict("xs" => (200, 1200), "ys" => (0.5, 0.2)),
        "ng" => Dict("xs" => (200, 600), "ys" => (0.5, 0.2)),
        )
    for (fuel, points) in ramp30_points
        fuel_idx = findall(case["genfuel"] .== fuel)
        slope = (
            (points["ys"][2] - points["ys"][1])
            / (points["xs"][2] - points["xs"][1]))
        intercept = points["ys"][1] - slope * points["xs"][1]
        for idx in fuel_idx
            norm_ramp = case["gen_pmax"][idx] * slope + intercept
            if case["gen_pmax"][idx] < points["xs"][1]
                norm_ramp = points["ys"][1]
            end
            if case["gen_pmax"][idx] > points["xs"][2]
                norm_ramp = points["ys"][2]
            end
            case["gen_ramp30"][idx] = norm_ramp * case["gen_pmax"][idx]
        end
    end
    
    return case
end


function build_model(case::Dict, start_index::Int=1, interval_length::Int=1)
    
    println("building sets")
    # Sets
    bus_name = ["b" * string(b) for b in case["busid"]]
    num_bus = length(case["busid"])
    bus_idx = 1:num_bus
    bus_id2idx = Dict(case["busid"] .=> bus_idx)
    branch_ac_name = ["l" * string(b) for b in case["branchid"]]
    if "dclineid" in keys(case)
        branch_dc_name = ["d" * string(d) for d in case["dclineid"]]
        branch_dc_rating = case["dcline_rating"]
    else
        branch_dc_name = String[]
        branch_dc_rating = Array{Float64}[]
    end
    branch_name = vcat(branch_ac_name, branch_dc_name)
    branch_rating = vcat(case["branch_rating"], branch_dc_rating)
    branch_rating[branch_rating .== 0] .= Inf
    #branch_rating = convert(Array{Float64,1}, branch_rating)
    num_branch = length(branch_name)
    branch_idx = 1:num_branch
    gen_name = ["g" * string(g) for g in case["genid"]]
    num_gen = length(case["genid"])
    gen_idx = 1:num_gen
    end_index = start_index+interval_length-1
    hour_name = ["h" * string(h) for h in range(start_index, stop=end_index)]
    num_hour = length(hour_name)
    hour_idx = 1:num_hour
    # Subsets
    gen_wind_idx = gen_idx[findall(case["genfuel"] .== "wind")]
    gen_solar_idx = gen_idx[findall(case["genfuel"] .== "solar")]
    gen_hydro_idx = gen_idx[findall(case["genfuel"] .== "hydro")]
    renewable_idx = sort(vcat(gen_wind_idx, gen_solar_idx, gen_hydro_idx))
    case["gen_pmax"][renewable_idx] .= Inf
    num_wind = length(gen_wind_idx)
    num_solar = length(gen_solar_idx)
    num_hydro = length(gen_hydro_idx)
    
    println("parameters")
    # Parameters
    # Generator topology matrix
    gen_bus_idx = [bus_id2idx[b] for b in case["gen_bus"]]
    gen_map = sparse(gen_bus_idx, gen_idx, 1)
    hydro_map = sparse(1:num_hydro, case["gen_bus"][gen_hydro_idx], 1)
    solar_map = sparse(1:num_solar, case["gen_bus"][gen_solar_idx], 1)
    wind_map = sparse(1:num_wind, case["gen_bus"][gen_wind_idx], 1)
    # Branch connectivity matrix
    branch_to_idx = [bus_id2idx[b] for b in case["branch_to"]]
    branch_from_idx = [bus_id2idx[b] for b in case["branch_from"]]
    branches_to = sparse(branch_to_idx, branch_idx, 1, num_bus, num_branch)
    branches_from = sparse(branch_from_idx, branch_idx, -1, num_bus, num_branch)
    branch_map = branches_to + branches_from
    # Demand by bus
    bus_df = DataFrames.DataFrame(
        name=case["busid"], load=case["bus_demand"], zone=case["bus_zone"])
    zone_demand = DataFrames.by(bus_df, :zone, :load => sum)
    zone_list = sort(collect(Set(case["bus_zone"])))
    num_zones = length(zone_list)
    zone_idx = 1:num_zones
    zone_id2idx = Dict(zone_list .=> zone_idx)
    bus_df_with_zone_load = join(bus_df, zone_demand, on = :zone)
    bus_share = bus_df[:, :load] ./ bus_df_with_zone_load[:, :load_sum]
    bus_zone_idx = [zone_id2idx[z] for z in case["bus_zone"]]
    zone_to_bus_shares = sparse(bus_zone_idx, bus_idx, bus_share)
    # Profiles
    simulation_demand = Matrix(case["demand"][start_index:end_index, 2:end])
    bus_demand = transpose(simulation_demand * zone_to_bus_shares)
    simulation_hydro = Matrix(case["hydro"][start_index:end_index, 2:end])
    simulation_solar = Matrix(case["solar"][start_index:end_index, 2:end])
    simulation_wind = Matrix(case["wind"][start_index:end_index, 2:end])
    
    # Model
    m = JuMP.direct_model(Gurobi.Optimizer(Method=2, Crossover=0))
    
    println("variables")
    # Variables
    JuMP.@variable(m, pg[gen_idx,hour_idx] >= 0)
    JuMP.@variable(m, pf[branch_idx,hour_idx])
    JuMP.@variable(m, theta[bus_idx,hour_idx])
    
    println("constraints")
    # Constraints
    println("powerbalance")
    JuMP.@constraint(m, powerbalance, (
        gen_map * pg + branch_map * pf .== bus_demand))
    if length(hour_idx) > 1
        println("rampup")
        noninf_ramp_idx = findall(case["gen_ramp30"] .!= Inf)
        JuMP.@constraint(m, rampup[i = noninf_ramp_idx, h = 1:(num_hour-1)], (
            pg[i,h+1] - pg[i,h] <= case["gen_ramp30"][i] * 2)
            )
        println("rampdown")
        JuMP.@constraint(m, rampdown[i = noninf_ramp_idx, h = 1:(num_hour-1)],
            case["gen_ramp30"][i] * -2 <= pg[i, h+1] - pg[i, h]  
            )
    end
    println("gen_min")
    JuMP.@constraint(m, gen_min[i = gen_idx, h = hour_idx], (
        pg[i, h] >= case["gen_pmin"][i]))
    println("gen_max")
    noninf_pmax = findall(case["gen_pmax"] .!= Inf)
    JuMP.@constraint(m, gen_max[i = noninf_pmax, h = hour_idx], (
        pg[i, h] <= case["gen_pmax"][i]))
    println("branch_min")
    noninf_branch_idx = findall(branch_rating .!= Inf)
    JuMP.@constraint(m, branch_min[br = noninf_branch_idx, h = hour_idx], (
        -branch_rating[br] <= pf[br, h]))
    println("branch_max")
    JuMP.@constraint(m, branch_max[br = noninf_branch_idx, h = hour_idx], (
        pf[br, h] <= branch_rating[br]))
    println("branch_angle")
    sparse_reactance = sparse(branch_idx, branch_idx, case["branch_reactance"])
    JuMP.@constraint(m, branch_angle, (
        sparse_reactance * pf .== transpose(branch_map) * theta))
    println("hydro_fixed")
    JuMP.@constraint(m, hydro_fixed[i = 1:num_hydro, h = hour_idx], (
        pg[gen_hydro_idx[i], h] == simulation_hydro[h, i]))
    println("solar_max")
    JuMP.@constraint(m, solar_max[i = 1:num_solar, h = hour_idx], (
        pg[gen_solar_idx[i], h] <= simulation_solar[h, i]))
    println("wind_max")
    JuMP.@constraint(m, wind_max[i = 1:num_wind, h = hour_idx], (
        pg[gen_wind_idx[i], h] <= simulation_wind[h, i]))
    println("objective")
    JuMP.@objective(m, Min, (0
        + num_hour * sum(case["gen_b_new"])
        + sum(reshape(case["gen_a_new"], (1, num_gen)) * pg)))
    
    return m
    
end

function solve_model(m)
    JuMP.optimize!(m)
end

# Module end
end
