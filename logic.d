import std.stdio;
import std.conv;
import std.getopt;

import speccomp, driver;

immutable string VERSION = "1.0";

ulong default_sims = 1000;

int main(string[] args) {

    bool batch;
    bool abort;
    bool verbose;
    try {
        getopt(args,
                "batch|b", &batch,
                "abort|q", &abort,
                "verbose|v", &verbose,
                "sims", &default_sims
              );
    } catch (Exception e) {
        writeln("error parsing arguments");
        return 1;
    }

    if (args.length == 1) {
        writeln("Syntax: logic [opts] files...");
        return 1;
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
            return 1;
        }
    }

    bool check_result = m.run_checks(verbose);
    if (abort && check_result)
        return 1;
    
    if (batch)
        return check_result ? 1 : 0;

    if (m.root is null) {
        writeln("error: no root declared to instantiate");
        return 1;
    }
    
    m.instantiate();
    
    m.launch!(Prompt)();

    return 0;
}

class LoadingException : Throwable {
    ulong line;
    this(string msg, ulong l = __LINE__) {
        line = l;
        super(msg);
    }
}

class RuntimeException : Throwable {
    ulong line;
    this(string msg, ulong l = __LINE__) {
        line = l;
        super(msg);
    }
}

class LogicMaster {
    static bool[char] seperators;
    static Gate[string] gate_names;
    static Status[string] constant_ports;
    static SpecialComponent function(string[]) [string] special_names;
    
    static this() {
        seperators = [
            ' ':false, '\t':false, ',':true, ';':true, '(':true, ')':true,
            '[':true, ']':true, '{':true, '}':true, '<':true, '>':true, '@':true
        ];
        gate_names = [
            "-":Gate.NONE, "!":Gate.NOT,
            "&":Gate.AND, "|":Gate.OR, "^":Gate.XOR,
            "!&":Gate.NAND, "!|":Gate.NOR, "!^":Gate.XNOR,
            "*":Gate.NTRN, "*P":Gate.PTRN, "*N":Gate.NTRN,
            "-L":Gate.PL, "-H":Gate.PH,
        ];
        constant_ports = [
            "_X":Status.X, "_E":Status.E,
            "_L":Status.L, "_H":Status.H
        ];
        special_names = [
            "%mem":&SCMemory.create
        ];
    }
    
    Component[string] components;
    Component root;
    Check[][string] checks;
    
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
                        throw new LoadingException("unexpected end of tokens in toplevel");
                    
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
                case "check":
                    if (tokens.length < 4)
                        throw new LoadingException("unexpected end of tokens in toplevel");
                    
                    string name = tokens[1];

                    Check ch = new Check(default_sims);

                    tokens = parse_check(tokens[2..$], ch, name);

                    checks[name] ~= ch;
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
                case "+": //gates & components
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
        
        foreach (p; c.inputs)
            p.is_input = true;
        c.simplify();
        
        return tokens[1..$];
    }
    
    string[] parse_portlist(string[] tokens, Component c, ref Port[] plist) {
        for (ulong i=0; i < tokens.length-1; i++) { 
            if (tokens[i] == ";")
                return tokens[i+1..$];
            
            if (tokens[i] == ",")
                continue;
            
            if (!valid_name(tokens[i]))
                throw new LoadingException("invalid name token "~tokens[i]~" in component "~c.name);
            
            if (tokens[i] in c.ports)
                throw new LoadingException("duplicate name "~tokens[i]~" in component "~c.name);
            
            ulong width;
            
            if (i+3 <= tokens.length && tokens[i+1] == "@") {
                try {
                    width = to!ulong(tokens[i+2]);
                } catch (ConvException ce) {
                    throw new LoadingException("invalid port width for port "~tokens[i]~" in component "~c.name);
                }
            } else {
                width = 1;
            }
            
            if (width == 1) {
                auto p = new Port(tokens[i],true,plist.length);
                
                c.ports[tokens[i]] = p;
                
                plist ~= p;
                
            } else if (width == 0) {
                throw new LoadingException("zero-width port "~tokens[i]~" in component "~c.name);
            } else {
                Port[] group;
                foreach (j; 0 .. width) {
                    string name = tokens[i]~"."~to!string(j);
                    
                    group ~= new Port(name,true,plist.length);
                    
                    c.ports[name] = group[$-1];
                    
                    plist ~= group[$-1];
                }
                c.groups[tokens[i]] = group;
                
                i += 2;
            }
            
        }
        throw new LoadingException("missing ; token in component "~c.name);
    }
    
    string[] parse_gate(string[] tokens, Component c) {
        
        bool after = false;
        bool missing = true;
        
        Gate gate;
        Component sub;
        
        SpecialComponent special;
        
        Port[] inputs, outputs;
        
        Status[ulong] constants;
        bool[ulong] ignores;
        
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
                } else if (tokens[i+1] in special_names) {
                    gate = Gate.SPC;
                    
                    string sname = tokens[i+1];
                    
                    string[] args;
                    for (; tokens[i+2] != "]"; i++) {
                        if (i+2 == tokens.length)
                            throw new LoadingException("missing ] after gate in component "~c.name);
                        args ~= tokens[i+2];
                    }
                    
                    special = special_names[sname](args);
                    
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
            } else if (!after && tokens[i] in constant_ports) {
                constants[inputs.length+constants.length] = constant_ports[tokens[i]];
            } else if (after && tokens[i] == "_") {
                ignores[outputs.length+ignores.length] = true;
            } else if (tokens[i] in c.groups) {
                if (after) {
                    outputs ~= c.groups[tokens[i]];
                } else {
                    inputs ~= c.groups[tokens[i]];
                }
            } else {
                throw new LoadingException("unknown port "~tokens[i]~" in component "~c.name);
            }
            i++;
        }
        
        if (missing) {
            throw new LoadingException("unexpected end of tokens in component "~c.name);
        }
        
        Port g = new Port("_g"~to!string(c.ngates++),false,0);
        
        g.gate = gate;
        g.sub = sub;
        g.special = special;
        
        g.constant_inputs = constants;
        
        if (g.gate == Gate.SUB) {
            if (outputs.length+ignores.length != sub.outputs.length)
                throw new LoadingException("incorrect number of outputs for instance of component "~sub.name~" in component "~c.name);
        } else if (g.gate == Gate.SPC) {
            if (outputs.length+ignores.length != special.num_outputs)
                throw new LoadingException("incorrect number of outputs for instance of special component "~special.name~" in component "~c.name);
        } else if (outputs.length > 1) {
            throw new LoadingException("too many outputs for gate "~to!string(gate)~" in component "~c.name);
        }
        
        if (g.gate == Gate.SUB) {
            if (inputs.length+constants.length != sub.inputs.length)
                throw new LoadingException("incorrect number of inputs for instance of component "~sub.name~" in component "~c.name);
        } else if (g.gate == Gate.SPC) {
            if (inputs.length+constants.length != special.num_inputs)
                throw new LoadingException("incorrect number of inputs for instance of special component "~special.name~" in component "~c.name);
        } else if (inputs.length + constants.length != gate_inputs(g.gate)) {
            throw new LoadingException("incorrect number of inputs for gate "~to!string(g.gate)~" in component "~c.name);
        }
        ulong p;
        foreach (j; 0 .. outputs.length + ignores.length) {
            if (j in ignores) {
                g.outputs ~= Connection(null);
            } else {
                g.outputs ~= Connection(outputs[p++], j, 0);
            }
        }
        
        p = 0;
        foreach (j; 0 .. inputs.length + constants.length) {
            if (j in constants) {
                continue;
            } else {
                inputs[p++].outputs ~= Connection(g, 0, j);
            }
        }
        
        c.ports[g.name] = g;
        
        return tokens;
    }

    string[] parse_check(string[] tokens, Check ch, string name) {
        if (tokens[0] != "{")
            throw new LoadingException("bad token in check for "~name);

        tokens = tokens[1..$];

        while (tokens[0] != "}") {
           switch (tokens[0]) {
                case "<":
                    CheckAction act = new CheckAction(CheckActionType.INPUT);
                    tokens = parse_checkaction(tokens[1..$], act);
                    ch.actions ~= act;
                    break;
                case ">":
                    CheckAction act = new CheckAction(CheckActionType.OUTPUT);
                    tokens = parse_checkaction(tokens[1..$], act);
                    ch.actions ~= act;
                    break;
                default:
                    throw new LoadingException("unexpected token "~tokens[0]~" in check for "~name);
                    break;
            }
            if (tokens.length == 0)
                throw new LoadingException("unexpected end of tokens in check for "~name);
        }
        
        return tokens[1..$];
    }

    string[] parse_checkaction(string[] tokens, CheckAction act) {
        ulong i = 0;
        while (tokens[i] != ";") {
            switch (tokens[i]) {
                case "X":
                    act.status[i] = Status.X;
                    break;
                case "E":
                    act.status[i] = Status.E;
                    break;
                case "L":
                    act.status[i] = Status.L;
                    break;
                case "H":
                    act.status[i] = Status.H;
                    break;
                case "_":
                    break;
                default:
                    throw new LoadingException("unknown status "~tokens[i]~" in check action");
            }
            if (++i == tokens.length)
                throw new LoadingException("unexpected end of tokens in check action");
        }

        return tokens[i+1..$];
    }
    
    string[] tokenize(File f) {
        string[] tokens;
        string t;
        bool keep;
        bool comment_trans;
        ulong comment_on;
        foreach (line; f.byLine) {
            foreach (ch; line) {
                if (ch == '/') {
                    if (comment_on > 0 && comment_trans) {
                        comment_on--;
                        comment_trans = false;
                        continue;
                    } else {
                        comment_trans = true;
                    }
                } else if (ch == '*') {
                    if (comment_on > 0) {
                        comment_trans = true;
                    } else if (comment_trans) {
                        comment_on++;
                        if (t.length > 0) {
                            if (t[$-1] == '/') {
                                if (t.length > 2)
                                    tokens ~= t[0..$-1];
                            } else {
                                tokens ~= t;
                            }
                            t = "";
                        }
                    }
                }
                if (comment_on == 0) {
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
        if ((name[0] >= 'a' && name[0] <= 'z') || (name[0] >= 'A' && name[0] <= 'Z')) {
            foreach (ch; name) {
                if (ch == '.')
                    return false;
            }
            return true;
        }
        return false;
    }
    
    static ulong gate_inputs(Gate g) {
        if (g == Gate.NONE || g == Gate.NOT || g == Gate.PL || g == Gate.PH)
            return 1;
        return 2;
    }

    void instantiate() {
        root_instance = root.instantiate();
        root_instance.reset();
    }
 
    //----functionality checking----//

    bool run_checks(bool verbose) {
        ulong errors, total;
        foreach (name, checklist; checks) {
            foreach (ch; checklist) {
                CheckResult r = ch.check(components[name]);
                if (r.type != CheckResultType.PASS)
                    errors++;
                if (verbose) {
                    final switch (r.type) {
                        case CheckResultType.PASS:
                            writeln("TEST ",total," : PASS");
                            break;
                        case CheckResultType.UNSTABLE:
                            writeln("TEST ",total," : UNSTABLE (line ",r.line,")");
                            break;
                        case CheckResultType.FAIL:
                            string s, s2;
                            foreach (i; 0 .. r.actual.length) {
                                if (i in r.expected)
                                    s ~= " "~to!string(r.expected[i]);
                                else
                                    s ~= " _";
                            }
                            foreach (stat; r.actual) {
                                s2 ~= " "~to!string(stat);
                            }
                            writeln("TEST ",total, " : FAIL (expected",s,", got",s2,"; line ",r.line,")");
                            break;
                    }
                }
                total++;
            }
        }
        if (verbose && errors > 0)
            writeln("Warning: ",errors,"/",total," checks failed");
        return errors > 0;
    }
    
   
    //----interactive prompt----//
    
   void launch(T : Driver)() {
        T.reset(this);
        T.run();
    }
    
    //----simulation----//
    static long simulate(ComponentInstance main, ulong sims, out bool stable) {
        ulong i = 0;
        while ((sims == 0 || sims-- > 1)) {
            if (!step(main)) {
                stable = true;
                break;
            }
            i++;
        }
        return i;
    }
    
    static bool step(ComponentInstance main) {
        main.recalculate();
        return main.propogate();
    }
    
    //----runtime modification----//
    void update_inputs(Component m) {
        foreach (c; components) {
            foreach (p; c.ports) {
                if (p.gate == Gate.SUB && p.sub == m) {
                    p.constant_inputs[m.inputs.length-1] = Status.X;
                }
            }
        }
    }
    void update_outputs(Component m) {
        foreach (c; components) {
            foreach (p; c.ports) {
                if (p.gate == Gate.SUB && p.sub == m) {
                    p.outputs ~= Connection(null);
                }
            }
        }
    }
    void remove_port(Component m, string name) {
        Port rp = m.ports[name];
        
        m.remove_port(name);
        
        if (rp.is_pin) {
            if (rp.is_input) {
                foreach (c; components) {
                    if (c == m)
                        continue;
                    foreach (p; c.ports) {
                        if (p.gate == Gate.SUB && p.sub == m) {
                            if (rp.num in p.constant_inputs) {
                                p.constant_inputs.remove(rp.num);
                            }
                        }
                        foreach (con; p.outputs) {
                            if (con.port !is null && con.port.gate == Gate.SUB && con.port.sub == m && con.dest == rp.num) {
                                con.port = null;
                            }
                        }
                    }
                }
            } else {
                foreach (c; components) {
                    if (c == m)
                        continue;
                    foreach (p; c.ports) {
                        if (p.gate == Gate.SUB && p.sub == m) {
                            foreach (n,con; p.outputs.dup) {
                                if (con.source == rp.num) {
                                    p.outputs = p.outputs[0..n]~(n+1<p.outputs.length ? p.outputs[n..$] : []);
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

class Component {
    string name;
    
    ulong ngates;
    Port[string] ports;
    
    Port[][string] groups;
    
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
            if (port.constant_inputs.length > 0) {
                foreach (p,s; port.constant_inputs)
                writeln("      _",s," -> ",port,"[",p,"]");
            }
        }
    }
    
    void simplify() {
        Connection[][Port] inputs;
        foreach (p; ports) {
            foreach (con; p.outputs) {
                if (con.port is null)
                    continue;
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
        
        foreach (n,g; groups.dup) {
            bool rem = true;
            foreach (p; g) {
                if (p !in inputs) {
                    rem = false;
                    break;
                }
            }
            if (rem)
                groups.remove(n);
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
    
    //runtime modification
    
    void add_port(string name, bool is_pin, Gate g = Gate.NONE, Component c = null) {
        if (name in ports) {
            throw new RuntimeException("duplicate port name");
        }
        ports[name] = new Port(name, is_pin, 0);
        ports[name].gate = g;
        ports[name].sub = c;
    }
    
    void add_ext_port(string name, bool is_input) {
        if (name in ports) {
            throw new RuntimeException("duplicate port name");
        }
        
        if (is_input) {
            ports[name] = new Port(name, true, inputs.length);
            inputs ~= ports[name];
            ports[name].is_input = true;
        } else {
            ports[name] = new Port(name, true, outputs.length);
            outputs ~= ports[name];
        }
    }
    
    void remove_port(string name) {
        if (name !in ports) {
            throw new RuntimeException("no such port");
        }

        foreach (con; ports[name].outputs) {
            con.port.constant_inputs[con.dest] = Status.X;
        }

        foreach (p; ports) {
            foreach (con; p.outputs) {
                if (con.port == ports[name]) {
                    con.port = null;
                }
            }
        }

        if (ports[name].is_pin) {
            ulong n = ports[name].num;
            if (ports[name].is_input) {
                inputs = inputs[0..n]~(n+1<inputs.length ? inputs[n..$] : []);
            } else {
                outputs = outputs[0..n]~(n+1<outputs.length ? outputs[n..$] : []);
            }
        }

        ports.remove(name);
    }
}

enum Gate {
    NONE, NOT, AND, OR, XOR, NAND, NOR, XNOR, PTRN, NTRN, SUB, PL, PH, SPC
}

struct Connection {
    Port port;
    ulong source, dest;
    string toString() {
    return "("~to!string(source)~" "~(port is null ? "<null>" : port.name)~" "~to!string(dest)~")";
    }
}

class Port {
    string name;
    bool is_pin, internal, is_input;
    Gate gate;
    Component sub;
    SpecialComponent special;
    ulong num;
    
    Status[ulong] constant_inputs;
    
    Connection[] outputs;
    
    //Port[][] outputs;
    
    
    this(string name, bool is_pin, ulong num) {
        this.name = name;
        this.is_pin = is_pin;
        this.num = num;
    }
    
    override string toString() {
        if (is_pin)
            return name;
        else if (gate == Gate.SUB)
            return name ~ "_" ~ sub.name;
        else if (gate == Gate.SPC)
            return name ~ "_" ~ special.name;
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
                string name;
                if (con.port is null)
                    name = "_";
                else
                    name = con.port.name;
                writeln(p.type, "[",con.source,"] -> ", name, "[",con.dest,"] := ", p.status_out[con.source]);
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
        bool change = false;
        
        foreach (child; children) {
            if (child.type.gate == Gate.SUB) {
                if (child.sub_instance.propogate()) {
                    change = true;
                }
            } else if (child.type.gate == Gate.SPC && child.type.special.delay) {
                change = true;
            }

            foreach (outp; child.type.outputs) {
                if (outp.port is null)
                    continue;
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
                               [Status.E, Status.L] : Status.L,
                               [Status.E, Status.H] : Status.E,
                               
                               [Status.L, Status.X] : Status.L,
                               [Status.L, Status.E] : Status.L,
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
                               [Status.E, Status.H] : Status.H,
                               
                               [Status.L, Status.X] : Status.E,
                               [Status.L, Status.E] : Status.E,
                               [Status.L, Status.L] : Status.L,
                               [Status.L, Status.H] : Status.H,
                               
                               [Status.H, Status.X] : Status.H,
                               [Status.H, Status.E] : Status.H,
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
                               [Status.E, Status.L] : Status.H,
                               [Status.E, Status.H] : Status.E,
                               
                               [Status.L, Status.X] : Status.H,
                               [Status.L, Status.E] : Status.H,
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
                               [Status.E, Status.H] : Status.L,
                               
                               [Status.L, Status.X] : Status.E,
                               [Status.L, Status.E] : Status.E,
                               [Status.L, Status.L] : Status.H,
                               [Status.L, Status.H] : Status.L,
                               
                               [Status.H, Status.X] : Status.L,
                               [Status.H, Status.E] : Status.L,
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
                               [Status.H, Status.H] : Status.H ],
                  Gate.PL  : [ [Status.X] : Status.L,
                               [Status.E] : Status.E,
                               [Status.L] : Status.L,
                               [Status.H] : Status.H ],
                  Gate.PH  : [ [Status.X] : Status.H,
                               [Status.E] : Status.E,
                               [Status.L] : Status.L,
                               [Status.H] : Status.H ]
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
        } else if (type.gate == Gate.SPC) {
            status_in = [];
            foreach (i; 0 .. type.special.num_inputs)
                status_in ~= Status.X;
            type.special.reset();
        } else if (LogicMaster.gate_inputs(type.gate) == 1) {
            status_in = [Status.X];
        } else {
            status_in = [Status.X, Status.X];
        }
        
        foreach (pos,s; type.constant_inputs) {
            status_in[pos] = s;
        }
        
        //foreach (k; status_out.dup.byKey)
        //    status_out.remove(k);
        if (type.gate == Gate.SUB) {
            status_out = [];
            foreach (i; 0 .. type.sub.outputs.length)
                status_out ~= Status.X;
        } else if (type.gate == Gate.SPC) {
            status_out = type.special.peek();
        } else {
            status_out = [Status.X];
        }
    }
    
    void recalculate() {
        if (type.gate == Gate.SUB) {
            sub_instance.component_in = status_in;
            sub_instance.recalculate();
            status_out = sub_instance.component_out;
        } else if (type.gate == Gate.SPC) {
            status_out = type.special.update(status_in);
        } else {
            status_out[0] = gate_lookup[type.gate].get(status_in,Status.E);
        }
    }
}

class Check {
    CheckAction[] actions;
    ulong sims;

    this(ulong sims) {
        this.sims = sims;
    }

    CheckResult check(Component c) {
        ComponentInstance root = c.instantiate();
        root.reset();
        foreach (ln,act; actions) {
            if (act.type == CheckActionType.INPUT) {
                foreach (i,ref cin; root.component_in) {
                    if (i in act.status)
                        cin = act.status[i];
                }
                bool stable;
                LogicMaster.simulate(root, sims, stable);
                if (!stable)
                    return CheckResult(CheckResultType.UNSTABLE, ln);
            } else {
                foreach (i, cin; root.component_out) {
                    if (i in act.status && cin != act.status[i])
                        return CheckResult(CheckResultType.FAIL, ln, act.status, root.component_out);
                }
            }
        }
        return CheckResult(CheckResultType.PASS);
    }
}

enum CheckResultType { PASS, FAIL, UNSTABLE }

struct CheckResult {
    CheckResultType type;
    ulong line;
    Status[ulong] expected;
    Status[] actual;
}

enum CheckActionType { INPUT, OUTPUT }

class CheckAction {
    CheckActionType type;
    Status[ulong] status;

    this(CheckActionType type) {
        this.type = type;
    }
}

interface SpecialComponent {
    static SpecialComponent create(string[] args);
    Status[] update(Status[] input);
    void reset();
    Status[] peek();
    @property ulong num_outputs();
    @property ulong num_inputs();
    @property string name();
    @property bool delay();
}
