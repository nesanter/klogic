import std.stdio;
import std.conv;

import logic;

interface Driver {
    static void run();
    static void reset(LogicMaster m);
}

class Prompt : Driver {
    
    static ComponentInstance[] views;
    static Port[] path;
    
    static bool autorun;
    
    static LogicMaster m;
    
    static void reset(LogicMaster m) {
        this.m = m;
        views = [m.root_instance];
        path = [];
        autorun = false;
    }
    
    static void run() {
        bool run = true;
        while (run) {
            write(">");
            string raw = readln();
            string[][] commands = [[""]];
            foreach (ch; raw) {
                if (ch == '\n')
                    break;
                if (ch == ' ' && commands[$-1][$-1].length > 0)
                    commands[$-1] ~= [""];
                else if (ch == ';')
                    commands ~= [""];
                else
                    commands[$-1][$-1] ~= ch;
            }
            
            if (commands.length == 0)
                continue;

            foreach (cmdset; commands) {
                if (cmdset.length > 1 && cmdset[$-1].length == 0)
                    cmdset = cmdset[0..$-1];
                if (run_command(cmdset))
                    run = false;
            }
        }
    }
    
    static bool run_command(string[] commands) {
        bool signed;
        switch (commands[0]) {
            case "q":
            case "quit":
                return true;
            break;
            case "r":
            case "run":
                ulong sims;
                if (commands.length == 1)
                    sims = default_sims;
                else {
                    try {
                        sims = to!ulong(commands[1]);
                        if (sims > 0)
                            sims++;
                    } catch (ConvException ce) {
                        writeln("number of trials must be an unsigned integer");
                        break;
                    }
                }
                sim(sims);
            break;
            case "S":
            case "show":
                if (commands.length == 1) {
                    foreach (c; m.components) {
                        c.print();
                    }
                } else if (commands[1] in m.components) {
                    m.components[commands[1]].print();
                } else {
                    writeln("no such component");
                }
            break;
            case "l":
            case "list":
                foreach (c; m.components) {
                    writeln(c.name);
                }
            break;
            case "R":
            case "reset":
                m.root_instance.reset();
            break;
            case "v":
            case "view":
                views[$-1].view();
            break;
            case "z":
            case "zoom":
                if (commands.length == 1) {
                    foreach (p; views[$-1].type.ports) {
                        if (p.gate == Gate.SUB) {
                            writeln(p.name, " (", p.sub.name, ")");
                        }
                    }
                } else {
                    bool fail = true;
                    foreach (p; views[$-1].children) {
                        if (p.type.gate == Gate.SUB && p.type.name == commands[1]) {
                            views ~= p.sub_instance;
                            path ~= p.type;
                            p.sub_instance.view_io();
                            fail = false;
                            break;
                        }
                    }
                    if (fail)
                        writeln("no such subcomponent");
                }
            break;
            case "P":
            case "path":
                write("/");
                foreach (p; path) {
                    write(p.name, "/");
                }
                writeln();
            break;
            case "u":
            case "up":
                if (views.length > 1) {
                    views = views[0..$-1];
                    path = path[0..$-1];
                } else
                    writeln("already at root");
            break;
            case "p":
            case "poke":
                if (commands.length == 1) {
                    views[$-1].view_io();
                } else {
                    
                    if (commands[1] !in views[$-1].children || !views[$-1].children[commands[1]].type.is_input) {
                        writeln("no such input pin");
                        break;
                    }
                    
                    ulong pnum = views[$-1].children[commands[1]].type.num;
                    
                    if (commands.length == 2) {
                        writeln(views[$-1].component_in[pnum]);
                    } else {
                        switch (commands[2]) {
                            case "h":
                            case "H":
                                views[$-1].component_in[pnum] = Status.H;
                            break;
                            case "l":
                            case "L":
                                views[$-1].component_in[pnum] = Status.L;
                            break;
                            case "x":
                            case "X":
                                views[$-1].component_in[pnum] = Status.X;
                            break;
                            case "e":
                            case "E":
                                views[$-1].component_in[pnum] = Status.E;
                            break;
                            default:
                                writeln("no such status");
                            break; 
                        }
                        if (autorun) {
                            sim(default_sims);
                        }
                    }
                }
            break;
            case "ss":
            case "sets":
                signed = true;
                goto case "set";
            case "s":
            case "set":
                if (commands.length == 1) {
                    if (views[$-1].type.groups.length > 0) {
                        foreach (name,g; views[$-1].type.groups) {
                            if (g[0].is_input)
                                write("  < ",name, ": ");
                            else
                                write("  > ",name, ": ");
                            foreach (p; g) {
                                if (p.is_input) {
                                    write(views[$-1].component_in[p.num]);
                                } else {
                                    write(views[$-1].component_out[p.num]);
                                }
                            }
                            writeln();
                        }
                    } else {
                        writeln("(no groups defined)");
                    }
                } else if (commands.length == 2) {
                    if (commands[1] in views[$-1].type.groups) {
                        bool e, x;
                        ulong n;
                        ulong bits;
                        if (views[$-1].type.groups[commands[1]][0].is_input) {
                            foreach_reverse (p; views[$-1].type.groups[commands[1]]) {
                                final switch (views[$-1].component_in[p.num]) {
                                    case Status.X:
                                        x = true;
                                    break;
                                    case Status.E:
                                        e = true;
                                    break;
                                    case Status.L:
                                        n <<= 1;
                                    break;
                                    case Status.H:
                                        n = (n << 1) | 1;
                                    break;
                                }
                                bits++;
                            }
                        } else {
                            foreach_reverse (p; views[$-1].type.groups[commands[1]]) {
                                final switch (views[$-1].component_out[p.num]) {
                                    case Status.X:
                                        x = true;
                                    break;
                                    case Status.E:
                                        e = true;
                                    break;
                                    case Status.L:
                                        n <<= 1;
                                    break;
                                    case Status.H:
                                        n = (n << 1) | 1;
                                    break;
                                }
                                bits++;
                            }
                        }
                        if (e)
                            writeln("(error)");
                        else if (x)
                            writeln("(undefined)");
                        else if (signed && (n & (1 << (bits-1))))
                            writeln("-",((n ^ ((1<<(bits))-1))+1));
                        else
                            writeln(n);
                    } else {
                        writeln("no such group");
                    }
                } else {
                    if (commands[1] !in views[$-1].type.groups) {
                        writeln("no such group");
                        break;
                    }
                    ulong n;
                    bool is_neg;
                    if (signed) {
                        try {
                            if (commands[2][0] == '-'){
                                is_neg = true;
                                n = to!ulong(commands[2][1..$]);
                            } else {
                                n = to!ulong(commands[2]);
                            }
                        } catch (ConvException ce) {
                            writeln("second argument must be signed integer");
                            break;
                        }
                        ulong bits = views[$-1].type.groups[commands[1]].length;
                        if (n > (1 << (bits-1))-(is_neg?0:1)) {
                            writeln("second argument exceeds width of group");
                            break;
                        }
                        if (is_neg)
                            n = (1 << bits-1) | ((n-1) ^ ((1 << bits-1)-1));
                    } else {
                        try {
                            n = to!ulong(commands[2]);
                        } catch (ConvException ce) {
                            writeln("second argument must be unsigned integer");
                            break;
                        }
                        if (n > (1 << views[$-1].type.groups[commands[1]].length)-1) {
                            writeln("second argument exceeds width of group");
                            break;
                        }
                    }
                    foreach (p; views[$-1].type.groups[commands[1]]) {
                        if (p.is_input) {
                            if (n & 1) {
                                views[$-1].component_in[p.num] = Status.H;
                            } else {
                                views[$-1].component_in[p.num] = Status.L;
                            }
                        } else {
                            if (n & 1) {
                                views[$-1].component_out[p.num] = Status.H;
                            } else {
                                views[$-1].component_out[p.num] = Status.L;
                            }
                        }
                        n >>= 1;
                    }
                    if (autorun) {
                        sim(default_sims);
                    }
                }
            break;
            case "root":
                if (commands.length == 1) {
                    if (m.root_instance == views[0])
                        writeln(m.root_instance.type.name);
                    else
                        writeln(m.root_instance.type.name, " (old: ",views[0].type.name,")");
                } else if (commands[1] == "set") {
                    m.root_instance = views[$-1];
                    writeln("new root: ",m.root_instance.type.name);
                } else if (commands[1] == "clear") {
                    m.root_instance = views[0];
                    writeln("root reset to ",m.root_instance.type.name);
                } else {
                    writeln("second argument must be either \"set\" or \"clear\"");
                }
            break;
            case "new":
                if (commands.length == 1) {
                    writeln("second argument must specify name of component");
                } else if (commands[1] in m.components) {
                    m.root = m.components[commands[1]];
                    m.instantiate();
                    views = [m.root_instance];
                    views[0].view_io();
                } else {
                    writeln("(disabled)");
                }
            break;
            case "add":
                if (commands.length == 1) {
                    writeln("second argument must specify name of port");
                } else if (commands[1] in views[$-1].type.ports) {
                    writeln("cannot create port with duplicate name");
                } else {
                    if (commands.length > 2) {
                        if (commands[2] == "input") {
                            views[$-1].type.add_ext_port(commands[1], true);
                            m.update_inputs(views[$-1].type);
                        } else if (commands[2] == "output") {
                            views[$-1].type.add_ext_port(commands[1], false);
                            m.update_outputs(views[$-1].type);
                        } else {
                            writeln("third argument, if present, must be \"input\" or \"output\"");
                        }
                    } else {
                        views[$-1].type.add_port(commands[1], true);
                    }
                    
                    m.instantiate();
                    views = [m.root_instance];
                    foreach (pp; path) {
                        views ~= views[$-1].children[pp.name].sub_instance;
                    }
                }
            break;
            case "change":
                Gate g;
                Component sub;
                SpecialComponent spec;
                ulong inp, outp;
                if (commands.length < 3) {
                    writeln("second and third argument must specify pin and new gate type");
                } else if (commands[1] !in views[$-1].type.ports) {
                    writeln("no such port");
                } else {
                    if (commands[2] in m.gate_names) {
                        g = m.gate_names[commands[2]];
                        outp = 1;
                        inp = m.gate_inputs(g);
                    } else if (commands[2] in m.components) {
                        g = Gate.SUB;
                        sub = m.components[commands[2]];
                        outp = sub.outputs.length;
                        inp = sub.inputs.length;
                    } else if (commands[2] in m.special_names) {
                        g = Gate.SPC;
                        try {
                            spec = m.special_names[commands[2]]((commands.length > 3 ? commands[3..$] : []));
                        } catch (LoadingException le) {
                            writeln(le.msg);
                            break;
                        }
                        inp = spec.num_inputs;
                        outp = spec.num_outputs;
                    } else {
                        writeln("no such gate/component");
                        break;
                    }
                    Port p = views[$-1].type.ports[commands[1]];
                    if (p.gate == g && p.sub == sub && p.special.name == spec.name) {
                        writeln("no change");
                        break;
                    }
                    ulong oldinp, oldoutp;
                    if (p.gate == Gate.SUB) {
                        oldinp = p.sub.inputs.length;
                        oldoutp = p.sub.outputs.length;
                    } else if (p.gate == Gate.SPC) {
                        oldinp = p.special.num_inputs;
                        oldoutp = p.special.num_outputs;
                    } else {
                        oldinp = m.gate_inputs(p.gate);
                        oldoutp = 1;
                    }
                    writeln("inp = ",inp,"; outp = ",outp);
                    if (inp > oldinp) {
                        foreach (i; oldinp .. inp) {
                            p.constant_inputs[i] = Status.X;
                        }
                    } else if (inp < oldinp) {
                        foreach (k; p.constant_inputs.dup.byKey) {
                            if (k >= inp)
                                p.constant_inputs.remove(k);
                        }
                        foreach (port; views[$-1].type.ports) {
                            foreach (ref con; port.outputs) {
                                if (con.port == p && con.dest >= inp) {
                                    writeln("nulling ",port.name);
                                    con.port = null;
                                    writeln(con);
                                }
                            }
                        }
                    }
                    if (outp > oldoutp) {
                        foreach (i; oldoutp .. outp) {
                            p.outputs ~= Connection(null, i, 0);
                        }
                    } else  if (outp < oldoutp) {
                        Connection[] keep;
                        foreach (con; p.outputs) {
                            if (con.source < outp) {
                                keep ~= con;
                            }
                        }
                        p.outputs = keep;
                    }
                    p.gate = g;
                    p.sub = sub;
                    p.special = spec;

                    views[$-1] = views[$-1].type.instantiate();
                    views[$-1].reset();
               }
            break;
            case "remove":
                if (commands.length == 1) {
                    writeln("second argument must specify name of port");
                } else if (commands[1] !in views[$-1].type.ports) {
                    writeln("no such port");
                } else {
                    m.remove_port(views[$-1].type, commands[1]);
                    
                    m.instantiate();
                    views = [m.root_instance];
                    foreach (pp; path) {
                        views ~= views[$-1].children[pp.name].sub_instance;
                    }
                }
            break;
           case "clear":
                write("\x1B[2J\x1B[H");
            break;
            case "auto":
                if (commands.length == 1) {
                    if (autorun)
                        writeln("on");
                    else
                        writeln("off");
                } else if (commands[1] == "on") {
                    autorun = true;
                    sim(default_sims);
                } else if (commands[1] == "off") {
                    autorun = false;
                } else {
                    writeln("second argument must be \"on\" or \"off\"");
                }
            break;
            case "help":
                writeln("valid commands:");
                writeln("help -- show this message");
                writeln("q|quit -- exits");
                writeln("reload -- reloads information from original files");
                writeln("S|show -- show the parsed logic data");
                writeln("");
                writeln("r|run [max=1000] -- runs the simulation until either stable or max rounds have passed");
                writeln("R|reset -- reset the simulation");
                writeln("v|view -- view current component (initially root)");
                writeln("z|zoom -- descend into sub-component");
                writeln("P|path -- display the view path");
                writeln("u|up -- ascend into parent component");
                writeln("root [set|clear] -- show, set, or reset root instance");
                writeln("p|poke [pin] [status] -- examine and change status of input pins");
                writeln("s|set [group] [value] -- examine and change status of pin groups");
                writeln("");
                writeln("new component -- creates a new view chain (old view chain is lost)");
                writeln("add name [type=pin] -- creates a new port at the current level");
                writeln("connect type inputs... outputs... -- create a new gate or component");
                writeln("version ",VERSION);
            break;
            case "":
            break;
            default:
                writeln("unknown command");
            break;
        }
        return false;
    }
    
    static void sim(ulong sims) {
        bool stable;
        ulong runs = m.simulate(m.root_instance, sims, stable);
        if (stable)
            writeln("simulation stable after ",runs," rounds");
        else
            writeln("simulation ended after ",runs," rounds");
    }
}
