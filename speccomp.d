import std.stdio;
import std.conv;

import logic;

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

    ulong delaycount;

    this(string[] args) {
        if (args.length > 0) {
            try {
                width = to!ulong(args[0]);
            } catch (ConvException ce) {
                throw new LoadingException("first argument to special component memory must be unsigned integer");
            }
        }
        if (args.length > 1) {
            try {
                size = to!ulong(args[1]);
            } catch (ConvException ce) {
                throw new LoadingException("second argument to special component memory must be unsigned integer");
            }
            addrwidth = 1;
            while ((1 << addrwidth) < size)
                addrwidth++;
        } else {
            size = (1 << width);
            addrwidth = width;
        }
        if (args.length > 2) {
            try {
                delaylength = to!ulong(args[2]);
            } catch (ConvException ce) {
                throw new LoadingException("third argument to special component memory must be unsigned integer");
            }
        }
        if (width > 64)
            throw new LoadingException("first argument to special component memory must not exceed 64");

        payload = new ulong[size];
        status = new Status[num_outputs];
    }

    void reset() {
        payload = new ulong[size];
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
                            if (err) {
                                foreach (n; 0 .. width)
                                    status[n] = Status.E;
                                delaycount = 0;
                                return status;
                            }
                        }
                        if (addr > payload.length) {
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
