import std.stdio;

import logic;

ulong[PortInstance] unique_ids;

void dump_start(File f, ComponentInstance ri, ulong max_depth) {
    f.writeln("digraph G {");
    
    f.writeln("graph [compound=true];");

    dump_ci(f,ri,max_depth);

    f.writeln("}");

}

void dump_ci(File f, ComponentInstance ci, ulong max_depth) {
    foreach (child; ci.children) {
        unique_ids[child] = unique_ids.length;
        if (max_depth > 0 && child.type.gate == Gate.SUB) {
            f.writeln("subgraph cluster_",unique_ids[child], " {");
            f.writeln("label=\"",child.type,"\";");
            dump_ci(f,child.sub_instance, max_depth-1);
            f.writeln("}");
        } else {
            if (child.type.is_input) {
                f.writeln(unique_ids[child], " [label=\"",child.type,"\",shape=\"triangle\"];");
            } else if (child.type.is_output) {
                f.writeln(unique_ids[child], " [label=\"",child.type,"\",shape=\"rectangle\"];");
            } else {
                f.writeln(unique_ids[child], " [label=\"",child.type,"\"];");
            }
        }
    }
    foreach (child; ci.children) {
        if (max_depth > 0 && child.type.gate == Gate.SUB) {
            foreach (con; child.type.outputs) {
                if (con.port !is null) {
                    if (con.port.gate == Gate.SUB) {
                        auto si = ci.children[con.port.name].sub_instance;
                        f.writeln(unique_ids[child.sub_instance.children[child.type.sub.outputs[con.source].name]]," -> ",unique_ids[si.children[si.type.inputs[con.dest].name]]);
                    } else
                        f.writeln(unique_ids[child.sub_instance.children[child.type.sub.outputs[con.source].name]]," -> ",unique_ids[ci.children[con.port.name]]);
                }
            }
        } else {
            f.write(unique_ids[child], " -> {");
            foreach (con; child.type.outputs) {
                if (con.port is null)
                    continue;
                else if (max_depth > 0 && con.port.gate == Gate.SUB) {
                    auto si = ci.children[con.port.name].sub_instance;
                    f.write(" ",unique_ids[si.children[si.type.inputs[con.dest].name]]);
                } else {
                    f.write(" ",unique_ids[ci.children[con.port.name]]);
                }
            }
            f.writeln(" }");
        }
    }
}
