import std.stdio;

import logic;

class SCMemory : SpecialComponent {
    static SpecialComponent create(string[] args) {
        writeln("args = ",args);
        return new SCMemory;
    }
    
    void reset() {
        
    }
    
    Status[] update(Status[] input) {
        return [];
    }
    
    @property ulong num_outputs() {
        return 2;
    }
    
    @property ulong num_inputs() {
        return 3;
    }
    
    @property string name() {
        return "%mem";
    }
}
