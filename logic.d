import std.stdio;
import std.conv;

void main(string[] args) {
    if (args.length == 1) {
        writeln("Syntax: logic files...");
        return;
    }
    
    LogicMaster m = new LogicMaster;
    foreach (arg; args[1..$]) {
        File f;
        try {
            f = File(arg, "r");
        } catch (Exception e) {
            writeln("cannot open file ",arg);
            continue;
        }
        try {
            m.load_logic(f);
        } catch (LoadingException e) {
            writeln("error loading ",arg,": ",e.msg," (line ",e.line,")");
            return;
        }
    }
    
    m.instantiate();
    
    m.prompt();

    
}

class LoadingException : Throwable {
    ulong line;
    this(string msg, ulong l = __LINE__) {
        line = l;
        super(msg);
    }
}

class LogicMaster {
    static bool[char] seperators;
    static Gate[string] gate_names;
    
    static this() {
        seperators = [
            ' ':false, '\t':false, ',':true, ';':true, '(':true, ')':true,
            '[':true, ']':true, '{':true, '}':true, '<':true, '>':true
        ];
        gate_names = [
            "-":Gate.NONE, "!":Gate.NOT,
            "&":Gate.AND, "|":Gate.OR, "^":Gate.XOR,
            "!&":Gate.NAND, "!|":Gate.NOR, "!^":Gate.XNOR,
            "T":Gate.NTRN, "PT":Gate.PTRN, "NT":Gate.NTRN
        ];
    }
    
    Component[string] components;
    Component root;
    
    ComponentInstance root_instance;
    
    //----parser----//
    
    bool load_logic(File f) {
        
        string[] tokens = tokenize(f);
        
        parse_toplevel(tokens);
        
        return true;
    }
    
    void parse_toplevel(string[] tokens) {
        
        string root_name;
        
        while (tokens.length > 0) {
            switch (tokens[0]) {
                case "component":
                    if (tokens.length < 4)
                        throw new LoadingException("too few tokens in toplevel");
                    
                    if (!valid_name(tokens[1]))
                        throw new LoadingException("invalid name token "~tokens[1]~" in toplevel");
                    
                    if (tokens[1] in components)
                        throw new LoadingException("duplicate component name "~tokens[1]);
                    
                    Component c = new Component(tokens[1]);
                    
                    tokens = parse_component(tokens[2..$], c);
                    
                    components[c.name] = c;
                    
                break;
                case "root":
                    if (tokens.length < 3)
                        throw new LoadingException("unexpected end of tokens in toplevel");
                    
                    if (tokens[1] !in components)
                        throw new LoadingException("root component "~tokens[1]~" not found");
                        
                    if (root_name.length > 0)
                        throw new LoadingException("multiple root declarations");
                    
                    root_name = tokens[1];
                    
                    if (tokens[2] != ";")
                        throw new LoadingException("root declaration without ; in toplevel");
                    
                    tokens = tokens[3..$];
                    
                break;
                default:
                    throw new LoadingException("bad token "~tokens[0]~" in toplevel");
            }
        }
        
        if (root_name == "")
            return;
            
        if (root !is null)
            throw new LoadingException("multiple files declare root in toplevel");
            
        root = components[root_name];
        
    }
    
    string[] parse_component(string[] tokens, Component c) {
        if (tokens[0] != "{")
            throw new LoadingException("bad token "~tokens[0]~" in component "~c.name);
        
        tokens = tokens[1..$];
        
        Port[] internals;
        
        while (tokens[0] != "}") {
            switch (tokens[0]) {
                case "<": //inputs
                    tokens = parse_portlist(tokens[1..$], c, c.inputs);
                break;
                case ">": //outputs
                    tokens = parse_portlist(tokens[1..$], c, c.outputs);
                break;
                case ".": //internals
                    tokens = parse_portlist(tokens[1..$], c, internals);
                break;
                case "+":
                    tokens = parse_gate(tokens[1..$], c);
                break;
                default:
                    throw new LoadingException("unexpected token "~tokens[0]~" in component "~c.name);
            }
            
            if (tokens.length == 0)
                throw new LoadingException("unexpected end of tokens in "~c.name);
        }
        
        foreach (p; internals)
            p.internal = true;
            
        //c.print();
        
        c.simplify();
        
        return tokens[1..$];
    }
    
    string[] parse_portlist(string[] tokens, Component c, ref Port[] plist) {
        foreach (i; 0 .. tokens.length-1) { 
            if (tokens[i] == ";")
                return tokens[i+1..$];
            
            if (tokens[i] == ",")
                continue;
            
            if (!valid_name(tokens[i]))
                throw new LoadingException("invalid name token "~tokens[i]~" in component "~c.name);
            
            if (tokens[i] in c.ports)
                throw new LoadingException("duplicate name "~tokens[i]~" in component "~c.name);
            
            auto p = new Port(tokens[i],true);
            
            c.ports[tokens[i]] = p;
            
            plist ~= p;
            
        }
        throw new LoadingException("missing ; token in component "~c.name);
    }
    
    string[] parse_gate(string[] tokens, Component c) {
        
        bool after = false;
        bool missing = true;
        
        Gate gate;
        Component sub;
        
        Port[] inputs, outputs;
        
        ulong i = 0;
        
        while (i < tokens.length-1) {
            if (tokens[i] == ";") {
                missing = false;
                tokens = tokens[i+1..$];
                break;
            }
            
            if (tokens[i] == "[") {
                if (i+2 >= tokens.length)
                    throw new LoadingException("unexpected end of tokens in component "~c.name);
                
                if (tokens[i+1] in gate_names) {
                    gate = gate_names[tokens[i+1]];
                } else if (tokens[i+1] in components) {
                    gate = Gate.SUB;
                    sub = components[tokens[i+1]];
                } else {
                    throw new LoadingException("unknown gate "~tokens[i+1]~" in component "~c.name);
                }
                
                if (tokens[i+2] != "]")
                    throw new LoadingException("missing ] after gate in component "~c.name);
                    
                after = true;
                i += 2;
            } else if (tokens[i] == ",") {
                //do nothing
            } else if (tokens[i] in c.ports) {
                if (after) {
                    outputs ~= c.ports[tokens[i]];
                } else {
                    inputs ~= c.ports[tokens[i]];
                }
            } else {
                throw new LoadingException("unknown port "~tokens[i]~" in component "~c.name);
            }
            i++;
        }
        
        if (missing) {
            throw new LoadingException("unexpected end of tokens in component "~c.name);
        }
        
        Port g = new Port("_g"~to!string(c.ngates++),false);
        
        g.gate = gate;
        g.sub = sub;
        
        if (g.gate == Gate.SUB) {
            if (outputs.length != sub.outputs.length)
                throw new LoadingException("incorrect number of outputs for instance of component "~sub.name~" in component "~c.name);
        } else if (outputs.length > 1) {
            throw new LoadingException("too many outputs for gate "~to!string(gate)~" in component "~c.name);
        }
        
        foreach (j,p; outputs) {
            g.outputs ~= Connection(p,j,0);
        }
        
        foreach (j,p; inputs) {
            p.outputs ~= Connection(g,0,j);
        }
        
        c.ports[g.name] = g;
        
        return tokens;
    }
    
    string[] tokenize(File f) {
        string[] tokens;
        string t;
        bool keep;
        foreach (line; f.byLine) {
            foreach (ch; line) {
                if (is_token_seperator(ch, keep)) {
                    if (t.length > 0) {
                        tokens ~= t;
                        t = "";
                    }
                    if (keep) {
                        tokens ~= [ch];
                    }
                } else {
                    t ~= ch;
                }
            }
        }
        return tokens;
    }
    
    bool is_token_seperator(char c, ref bool keep) {
        if (c in seperators) {
            keep = seperators[c];
            return true;
        }
        return false;   
    }
    
    bool valid_name(string name) {
        if (name.length == 0)
            return false;
        if ((name[0] >= 'a' && name[0] <= 'z') || (name[0] >= 'A' && name[0] <= 'Z'))
            return true;
        return false;
    }
    
    void instantiate() {
        root_instance = root.instantiate();
        root_instance.reset();
    }
    
    //----interactive prompt----//
    
    void prompt() {
        ComponentInstance[] views = [root_instance];
        bool run = true;
        while (run) {
            write(">");
            string raw = readln();
            string[] commands = [""];
            foreach (ch; raw) {
                if (ch == '\n')
                    break;
                if (ch == ' ')
                    commands ~= [""];
                else
                    commands[$-1] ~= ch;
            }
            
            if (commands.length == 0)
                continue;
            
            switch (commands[0]) {
                case "quit":
                    run = false;
                break;
                case "run":
                    ulong sims;
                    if (commands.length == 1)
                        sims = 0;
                    else {
                        try {
                            sims = to!ulong(commands[1]);
                        } catch (ConvException ce) {
                            writeln("Syntax: run [trials]");
                            break;
                        }
                    }
                    ulong runs = simulate(sims);
                    writeln("simulation stable after ",runs," rounds");
                break;
                case "show":
                    if (commands.length == 1 || commands[1] == "components") {
                        foreach (c; components) {
                            c.print();
                        }
                    } else {
                        switch (commands[1]) {
                            case "root":
                                root.print();
                            break;
                            case "globals":
                                foreach (pin; root.inputs) {
                                    writeln(pin);
                                }
                            break;
                            default:
                                writeln("Syntax: show [components|root]");
                            break;
                        }
                    }
                break;
                case "reset":
                    root_instance.reset();
                break;
                case "view":
                    views[$-1].view();
                break;
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
                                p.sub_instance.view();
                                fail = false;
                                break;
                            }
                        }
                        if (fail)
                            writeln("no such subcomponent");
                    }
                break;
                case "up":
                    if (views.length > 1)
                        views = views[0..$-1];
                    else
                        writeln("already at root");
                break;
                case "poke":
                    if (commands.length == 1) {
                        views[$-1].view_io();
                    } else {
                        
                        ulong pnum;
                        
                        foreach (i,pin; views[$-1].type.inputs) {
                            if (pin.name == commands[1]) {
                                pnum = i+1;
                            }
                        }
                        
                        if (pnum == 0) {
                            writeln("no such input pin");
                            break;
                        }
                        pnum--;
                        
                        writeln(pnum);
                        
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
                        }
                    }
                break;
                case "":
                break;
                default:
                    writeln("unknown command");
                break;
            }
        }
    }
    
    //----simulation----//
    ulong simulate(ulong sims) {
        ulong i = 0;
        while (step() && (sims == 0 || sims-- > 1)) {
            i++;
        }
        return i;
    }
    
    bool step() {
        root_instance.recalculate();
        return root_instance.propogate();
    }
}

class Component {
    string name;
    
    ulong ngates;
    Port[string] ports;
    
    Port[] inputs;
    Port[] outputs;
    this(string name) {
        this.name = name;
    }
    
    void print() {
        writeln("component: ",name);
        writeln("  inputs: ",inputs);
        writeln("  outputs: ",outputs);
        writeln("  graph:");
        foreach (port; ports) {
            writeln("    ",port," -> ",port.outputs);
        }
    }
    
    void simplify() {
        Connection[][Port] inputs;
        foreach (p; ports) {
            foreach (con; p.outputs) {
                if (con.port in inputs)
                    inputs[con.port] ~= Connection(p, con.source, con.dest);
                else if (con.port.is_pin && con.port.internal)
                    inputs[con.port] = [Connection(p, con.source, con.dest)];
            }
        }
        
        foreach (n,p; ports.dup) {
            if (p in inputs) {
                
                //connect inputs to p to outputs of p
                foreach (cin; inputs[p]) {
                    foreach (cout; p.outputs) {
                        if (cout.port !in inputs)
                            cin.port.outputs ~= Connection(cout.port, cin.source, cout.dest);
                    }
                }
                
                //remove p from ports
                ports.remove(n);
            }
        }
        
        foreach (p; ports) {
            Connection[] keep;
            foreach (con; p.outputs) {
                if (con.port !in inputs)
                    keep ~= con;
            }
            p.outputs = keep;
        }
        
    }
    
    ComponentInstance instantiate() {
        auto ci = new ComponentInstance;
        ci.type = this;
        foreach (k,v; ports) {
            ci.children[k] = new PortInstance;
            ci.children[k].type = v;
            if (v.gate == Gate.SUB) {
                ci.children[k].sub_instance = v.sub.instantiate();
            }
        }
        return ci;
    }
}

enum Gate {
    NONE, NOT, AND, OR, XOR, NAND, NOR, XNOR, PTRN, NTRN, SUB
}

struct Connection {
    Port port;
    ulong source, dest;
}

class Port {
    string name;
    bool is_pin, internal;
    Gate gate;
    Component sub;
    
    Connection[] outputs;
    
    //Port[][] outputs;
    
    
    this(string name, bool is_pin) {
        this.name = name;
        this.is_pin = is_pin;
    }
    
    override string toString() {
        if (is_pin)
            return name;
        else if (gate == Gate.SUB)
            return name ~ "_" ~ sub.name;
        else
            return name ~ "_" ~ to!string(gate);
    }
}

enum Status {
    X, E, L, H
}

class ComponentInstance {
    PortInstance[string] children;
    Component type;
    
    Status[] component_in;
    Status[] component_out;
    
    void view() {
        writeln("viewing: ", type.name);
        foreach (portname; children.keys.sort) {
            PortInstance p = children[portname];
            foreach (con; p.type.outputs) {
                writeln(p.type, "[",con.source,"] -> ", con.port.name, "[",con.dest,"] := ", p.status_out[con.source]);
            }
        }
    }
    
    void view_io() {
        writeln("viewing: ", type.name);
        foreach (i,inp; type.inputs) {
            writeln("  < ",inp.name," := ",component_in[i]);
        }
        foreach (i,outp; type.outputs) {
            writeln("  > ",outp.name," := ",component_out[i]);
        }
    }
    
    void reset() {
        component_in = [];
        foreach (i; 0 .. type.inputs.length) {
            component_in ~= Status.X;
        }
        component_out = [];
        foreach (i; 0 .. type.outputs.length) {
            component_out ~= Status.X;
        }
        foreach (child; children) {
            child.reset();
        }
    }
    
    void recalculate() {
        foreach (i,inp; type.inputs) {
            children[inp.name].status_in = [component_in[i]];
        }
        foreach (child; children)
            child.recalculate();
    }
    
    bool propogate() {
        /*
        foreach (child; children) {
            foreach (outp; child.type.outputs) {
                
            }
        }
        */
        
        bool change = false;
        
        foreach (child; children) {
            if (child.type.gate == Gate.SUB)
                if (child.sub_instance.propogate()) {
                    change = true;
                }
            foreach (outp; child.type.outputs) {
                if (child.status_out[outp.source] != children[outp.port.name].status_in[outp.dest]) {
                    change = true;
                    children[outp.port.name].status_in[outp.dest] = child.status_out[outp.source];
                }
            }
        }
        
        foreach (i,outp; type.outputs) {
            if (component_out[i] != children[outp.name].status_out[0]) {
                change = true;
                component_out[i] = children[outp.name].status_out[0];
            }
        }
        
        return change;
    }
}

class PortInstance {
    Port type;
    
    static Status[Status[]][Gate] gate_lookup;
    
    static this() {
        gate_lookup = 
                 [Gate.NONE: [ [Status.X] : Status.X,
                               [Status.E] : Status.E,
                               [Status.L] : Status.L,
                               [Status.H] : Status.H ],
                               
                  Gate.NOT : [ [Status.X] : Status.E,
                               [Status.E] : Status.E,
                               [Status.L] : Status.H,
                               [Status.H] : Status.L ],
                               
                  Gate.AND : [ [Status.X, Status.X] : Status.E,
                               [Status.X, Status.E] : Status.E,
                               [Status.X, Status.L] : Status.L,
                               [Status.X, Status.H] : Status.E,
                               
                               [Status.E, Status.X] : Status.E,
                               [Status.E, Status.E] : Status.E,
                               [Status.E, Status.L] : Status.E,
                               [Status.E, Status.H] : Status.E,
                               
                               [Status.L, Status.X] : Status.L,
                               [Status.L, Status.E] : Status.E,
                               [Status.L, Status.L] : Status.L,
                               [Status.L, Status.H] : Status.L,
                               
                               [Status.H, Status.X] : Status.E,
                               [Status.H, Status.E] : Status.E,
                               [Status.H, Status.L] : Status.L,
                               [Status.H, Status.H] : Status.H ],
                               
                  Gate.OR  : [ [Status.X, Status.X] : Status.E,
                               [Status.X, Status.E] : Status.E,
                               [Status.X, Status.L] : Status.E,
                               [Status.X, Status.H] : Status.H,
                               
                               [Status.E, Status.X] : Status.E,
                               [Status.E, Status.E] : Status.E,
                               [Status.E, Status.L] : Status.E,
                               [Status.E, Status.H] : Status.E,
                               
                               [Status.L, Status.X] : Status.E,
                               [Status.L, Status.E] : Status.E,
                               [Status.L, Status.L] : Status.L,
                               [Status.L, Status.H] : Status.H,
                               
                               [Status.H, Status.X] : Status.H,
                               [Status.H, Status.E] : Status.E,
                               [Status.H, Status.L] : Status.H,
                               [Status.H, Status.H] : Status.H ],
                               
                  Gate.XOR : [ [Status.X, Status.X] : Status.E,
                               [Status.X, Status.E] : Status.E,
                               [Status.X, Status.L] : Status.E,
                               [Status.X, Status.H] : Status.E,
                               
                               [Status.E, Status.X] : Status.E,
                               [Status.E, Status.E] : Status.E,
                               [Status.E, Status.L] : Status.E,
                               [Status.E, Status.H] : Status.E,
                               
                               [Status.L, Status.X] : Status.E,
                               [Status.L, Status.E] : Status.E,
                               [Status.L, Status.L] : Status.L,
                               [Status.L, Status.H] : Status.H,
                               
                               [Status.H, Status.X] : Status.E,
                               [Status.H, Status.E] : Status.E,
                               [Status.H, Status.L] : Status.H,
                               [Status.H, Status.H] : Status.L ],
                               
                  Gate.NAND: [ [Status.X, Status.X] : Status.E,
                               [Status.X, Status.E] : Status.E,
                               [Status.X, Status.L] : Status.H,
                               [Status.X, Status.H] : Status.E,
                               
                               [Status.E, Status.X] : Status.E,
                               [Status.E, Status.E] : Status.E,
                               [Status.E, Status.L] : Status.E,
                               [Status.E, Status.H] : Status.E,
                               
                               [Status.L, Status.X] : Status.H,
                               [Status.L, Status.E] : Status.E,
                               [Status.L, Status.L] : Status.H,
                               [Status.L, Status.H] : Status.H,
                               
                               [Status.H, Status.X] : Status.E,
                               [Status.H, Status.E] : Status.E,
                               [Status.H, Status.L] : Status.H,
                               [Status.H, Status.H] : Status.L ],
                               
                  Gate.NOR : [ [Status.X, Status.X] : Status.E,
                               [Status.X, Status.E] : Status.E,
                               [Status.X, Status.L] : Status.E,
                               [Status.X, Status.H] : Status.L,
                               
                               [Status.E, Status.X] : Status.E,
                               [Status.E, Status.E] : Status.E,
                               [Status.E, Status.L] : Status.E,
                               [Status.E, Status.H] : Status.E,
                               
                               [Status.L, Status.X] : Status.E,
                               [Status.L, Status.E] : Status.E,
                               [Status.L, Status.L] : Status.H,
                               [Status.L, Status.H] : Status.L,
                               
                               [Status.H, Status.X] : Status.L,
                               [Status.H, Status.E] : Status.E,
                               [Status.H, Status.L] : Status.L,
                               [Status.H, Status.H] : Status.L ],
                               
                  Gate.XNOR: [ [Status.X, Status.X] : Status.E,
                               [Status.X, Status.E] : Status.E,
                               [Status.X, Status.L] : Status.E,
                               [Status.X, Status.H] : Status.E,
                               
                               [Status.E, Status.X] : Status.E,
                               [Status.E, Status.E] : Status.E,
                               [Status.E, Status.L] : Status.E,
                               [Status.E, Status.H] : Status.E,
                               
                               [Status.L, Status.X] : Status.E,
                               [Status.L, Status.E] : Status.E,
                               [Status.L, Status.L] : Status.H,
                               [Status.L, Status.H] : Status.L,
                               
                               [Status.H, Status.X] : Status.E,
                               [Status.H, Status.E] : Status.E,
                               [Status.H, Status.L] : Status.L,
                               [Status.H, Status.H] : Status.H ],
                               
                  Gate.PTRN: [ [Status.X, Status.X] : Status.X,
                               [Status.X, Status.E] : Status.E,
                               [Status.X, Status.L] : Status.X,
                               [Status.X, Status.H] : Status.X,
                               
                               [Status.E, Status.X] : Status.E,
                               [Status.E, Status.E] : Status.E,
                               [Status.E, Status.L] : Status.E,
                               [Status.E, Status.H] : Status.X,
                               
                               [Status.L, Status.X] : Status.E,
                               [Status.L, Status.E] : Status.E,
                               [Status.L, Status.L] : Status.L,
                               [Status.L, Status.H] : Status.X,
                               
                               [Status.H, Status.X] : Status.E,
                               [Status.H, Status.E] : Status.E,
                               [Status.H, Status.L] : Status.H,
                               [Status.H, Status.H] : Status.X ],
                               
                  Gate.NTRN: [ [Status.X, Status.X] : Status.X,
                               [Status.X, Status.E] : Status.E,
                               [Status.X, Status.L] : Status.X,
                               [Status.X, Status.H] : Status.X,
                               
                               [Status.E, Status.X] : Status.E,
                               [Status.E, Status.E] : Status.E,
                               [Status.E, Status.L] : Status.X,
                               [Status.E, Status.H] : Status.E,
                               
                               [Status.L, Status.X] : Status.E,
                               [Status.L, Status.E] : Status.E,
                               [Status.L, Status.L] : Status.X,
                               [Status.L, Status.H] : Status.L,
                               
                               [Status.H, Status.X] : Status.E,
                               [Status.H, Status.E] : Status.E,
                               [Status.H, Status.L] : Status.X,
                               [Status.H, Status.H] : Status.H ]
                 ];
                 
    }
    
    Status[] status_in;
    Status[] status_out;
    
    ComponentInstance sub_instance;
    
    void reset() {
        if (type.gate == Gate.SUB) {
            status_in = [];
            foreach (i; 0 .. type.sub.inputs.length)
                status_in ~= Status.X;
            sub_instance.reset();
        } else if (type.gate == Gate.NONE || type.gate == Gate.NOT) {
            status_in = [Status.X];
        } else {
            status_in = [Status.X, Status.X];
        }
        //foreach (k; status_out.dup.byKey)
        //    status_out.remove(k);
        if (type.gate == Gate.SUB) {
            status_out = [];
            foreach (i; 0 .. type.sub.outputs.length)
                status_out ~= Status.X;
        } else {
            status_out = [Status.X];
        }
    }
    
    void recalculate() {
        if (type.gate == Gate.SUB) {
            sub_instance.component_in = status_in;
            sub_instance.recalculate();
            status_out = sub_instance.component_out;
        } else {
            status_out[0] = gate_lookup[type.gate].get(status_in,Status.E);
        }
    }
}
