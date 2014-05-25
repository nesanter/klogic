import std.stdio;
import std.conv;

import logic;

/*
    Pinout:
    0 < CLK
    1 < WRITE
    2..2+addrwidth < ADDRESS;
    2+width < DATA_IN;
    0..width > DATA_OUT;

    Arguments:
    data width (1-64)
    address width (1-24)
    initial data file
    delay length
    
*/
class SCMemory : SpecialComponent {
    static SpecialComponent create(string[] args) {
        return new SCMemory(args);
    }

    ulong size;
    ulong width = 4, addrwidth;
    ulong delaylength = 4;

    bool clock;
    Status[] status;

    ulong[] payload;
    ulong[] initial;

    ulong delaycount;

    this(string[] args) {
        string initfname;
        if (args.length > 0) {
            try {
                width = to!ulong(args[0]);
            } catch (ConvException ce) {
                throw new LoadingException("first argument to special component memory must be unsigned integer");
            }
        }
        if (args.length > 1) {
            try {
                addrwidth = to!ulong(args[1]);
            } catch (ConvException ce) {
                throw new LoadingException("second argument to special component memory must be unsigned integer");
            }
        } else {
            addrwidth = width > 24 ? 24 : width;
        }
        if (args.length > 2) {
            initfname = args[2];
        }
        if (args.length > 3) {
            try {
                delaylength = to!ulong(args[3]);
            } catch (ConvException ce) {
                throw new LoadingException("fourth argument to special component memory must be unsigned integer");
            }
        }
        if (width > 64)
            throw new LoadingException("first argument to special component memory must be in the range [1,64]");
        if (addrwidth > 24)
            throw new LoadingException("second argument to special component memory must be in the range [1,24]");
        
        size = 1 << addrwidth;

        payload = new ulong[size];
        status = new Status[num_outputs];

        if (initfname != "") {
            File f;
            try {
                f = File(initfname,"r");
            } catch (Exception e) {
                throw new LoadingException("cannot open initial file for component memory");
            }
            foreach (line; f.byLine) {
                string s;
                foreach (ch; line) {
                    if (ch == ' ') {
                        if (s.length > 0) {
                            try {
                                initial ~= from_hex(s);
                            } catch (ConvException ce) {
                                throw new LoadingException("encountered bad value "~s~" in initial file for component memory");
                            }
                            if (initial[$-1] > (1 << width)) {
                                throw new LoadingException("value "~s~" in initial file is too large for component memory");
                            }
                        }
                        s = "";
                    } else {
                        s ~= ch;
                    }
                }
                try {
                    initial ~= from_hex(s);
                } catch (ConvException ce) {
                    throw new LoadingException("encountered bad value "~s~" in initial file for component memory");
                }
                if (initial[$-1] > (1 << width)) {
                    throw new LoadingException("value "~s~" in initial file is too large for component memory");
                }
                s = "";
            }
        }

        foreach (i,v; initial)
            payload[i] = v;
    }

    void reset() {
        payload = new ulong[](size);
        foreach (i,v; initial)
            payload[i] = v;
        delaycount = 0;
    }

    Status[] peek() {
        return status;
    }

    Status[] update(Status[] input) {
        if (input[0] == Status.X) {
            foreach (n; 0 .. width)
                status[n] = Status.E;
            delaycount = 0;
        } else if (input[0] == Status.L) {
            clock = false;
            delaycount = 0;
        } else if (input[0] == Status.H && !clock) {
            if (delaycount == 0) {
                delaycount = delaylength;
            } else if (delaycount > 1) {
                delaycount--;
            } else {
                delaycount = 0;
                clock = true;
                if (input[1] == Status.X || input[1] == Status.E) {
                    foreach (n; 0 .. width)
                        status[n] = Status.E;
                    delaycount = 0;
                } else {
                    bool err;
                    ulong addr, dat;
                    foreach (n; 0 .. addrwidth) {
                        if (input[2+n] == Status.E || input[2+n] == Status.X) {
                            err = true;
                            break;
                        } else if (input[2+n] == Status.H) {
                            addr |= (1 << n);
                        }
                    }
                    if (err) {
                        foreach (n; 0 .. width)
                            status[n] = Status.E;
                        delaycount = 0;
                    } else {
                        if (input[1] == Status.H) {
                            foreach (n; 0 .. width) {
                                if (input[2+addrwidth+n] == Status.X || input[2+addrwidth+n] == Status.E) {
                                    err = true;
                                    break;
                                } else if (input[2+addrwidth+n] == Status.H) {
                                    dat |= (1 << n);
                                }
                            }
                            if (err || addr > payload.length) {
                                foreach (n; 0 .. width)
                                    status[n] = Status.E;
                                delaycount = 0;
                                return status;
                            }
                            payload[addr] = dat;
                        }
                        if (addr >= payload.length) {
                            foreach (n; 0 .. width)
                                status[n] = Status.E;
                            delaycount = 0;
                        } else {
                            foreach (n; 0 .. width)
                                status[n] = (payload[addr] & (1<<n) ? Status.H : Status.L);
                        }
                    }
                }
            }
        }
        return status;
    }
    
    @property ulong num_outputs() {
        return width;
    }
    
    @property ulong num_inputs() {
        return width+addrwidth+2;
    }
    
    @property string name() {
        return "%mem";
    }

    @property bool delay() {
        return delaycount > 0;
    }
}


ulong from_hex(string s) {
    ulong n;
    foreach (ch; s) {
        n <<= 4;
        switch (ch) {
            case '0':
                break;
            case '1':
                n |= 1;
                break;
            case '2':
                n |= 2;
                break;
            case '3':
                n |= 3;
                break;
            case '4':
                n |= 4;
                break;
            case '5':
                n |= 5;
                break;
            case '6':
                n |= 6;
                break;
            case '7':
                n |= 7;
                break;
            case '8':
                n |= 8;
                break;
            case '9':
                n |= 9;
                break;
            case 'A':
                n |= 10;
                break;
            case 'B':
                n |= 11;
                break;
            case 'C':
                n |= 12;
                break;
            case 'D':
                n |= 13;
                break;
            case 'E':
                n |= 14;
                break;
            case 'F':
                n |= 15;
                break;
            default:
                throw new ConvException("");
        }
    }
    return n;
}


