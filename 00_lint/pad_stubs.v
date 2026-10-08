// Port-only stubs of the sky130_ef_io pad cells used by picorv32_top.
// The PDK models use tranif1 switch primitives that the linter rejects, so lint uses these.

module sky130_ef_io__gpiov2_pad_wrapped (
    IN_H,
    PAD_A_NOESD_H,
    PAD_A_ESD_0_H,
    PAD_A_ESD_1_H,
    PAD,
    DM,
    HLD_H_N,
    IN,
    INP_DIS,
    IB_MODE_SEL,
    ENABLE_H,
    ENABLE_VDDA_H,
    ENABLE_INP_H,
    OE_N,
    TIE_HI_ESD,
    TIE_LO_ESD,
    SLOW,
    VTRIP_SEL,
    HLD_OVR,
    ANALOG_EN,
    ANALOG_SEL,
    ENABLE_VDDIO,
    ENABLE_VSWITCH_H,
    ANALOG_POL,
    OUT,
    AMUXBUS_A,
    AMUXBUS_B,
    VSSA,
    VDDA,
    VSWITCH,
    VDDIO_Q,
    VCCHIB,
    VDDIO,
    VCCD,
    VSSIO,
    VSSD,
    VSSIO_Q
);
    input OUT;
    input OE_N;
    input HLD_H_N;
    input ENABLE_H;
    input ENABLE_INP_H;
    input ENABLE_VDDA_H;
    input ENABLE_VSWITCH_H;
    input ENABLE_VDDIO;
    input INP_DIS;
    input IB_MODE_SEL;
    input VTRIP_SEL;
    input SLOW;
    input HLD_OVR;
    input ANALOG_EN;
    input ANALOG_SEL;
    input ANALOG_POL;
    input [2:0] DM;
    inout VDDIO;
    inout VDDIO_Q;
    inout VDDA;
    inout VCCD;
    inout VSWITCH;
    inout VCCHIB;
    inout VSSA;
    inout VSSD;
    inout VSSIO_Q;
    inout VSSIO;
    inout PAD;
    inout PAD_A_NOESD_H,PAD_A_ESD_0_H,PAD_A_ESD_1_H;
    inout AMUXBUS_A;
    inout AMUXBUS_B;
    output IN;
    output IN_H;
    output TIE_HI_ESD, TIE_LO_ESD;
endmodule

module sky130_ef_io__vccd_hvc_pad (
    AMUXBUS_A,
    AMUXBUS_B,
    DRN_HVC,
    SRC_BDY_HVC,
    VSSA,
    VDDA,
    VSWITCH,
    VDDIO_Q,
    VCCHIB,
    VDDIO,
    VCCD,
    VCCD_PAD,
    VSSIO,
    VSSD,
    VSSIO_Q
);
    inout AMUXBUS_A;
    inout AMUXBUS_B;
    inout DRN_HVC;
    inout SRC_BDY_HVC;
    inout VDDIO;
    inout VDDIO_Q;
    inout VDDA;
    inout VCCD;
    inout VCCD_PAD;
    inout VSWITCH;
    inout VCCHIB;
    inout VSSA;
    inout VSSD;
    inout VSSIO_Q;
    inout VSSIO;
endmodule

module sky130_ef_io__vssd_hvc_pad (
    AMUXBUS_A,
    AMUXBUS_B,
    DRN_HVC,
    SRC_BDY_HVC,
    VSSA,
    VDDA,
    VSWITCH,
    VDDIO_Q,
    VCCHIB,
    VDDIO,
    VCCD,
    VSSIO,
    VSSD,
    VSSD_PAD,
    VSSIO_Q
);
    inout AMUXBUS_A;
    inout AMUXBUS_B;
    inout DRN_HVC;
    inout SRC_BDY_HVC;
    inout VDDIO;
    inout VDDIO_Q;
    inout VDDA;
    inout VCCD;
    inout VSWITCH;
    inout VCCHIB;
    inout VSSA;
    inout VSSD;
    inout VSSD_PAD;
    inout VSSIO_Q;
    inout VSSIO;
endmodule

module sky130_ef_io__vddio_hvc_pad (
    AMUXBUS_A,
    AMUXBUS_B,
    DRN_HVC,
    SRC_BDY_HVC,
    VSSA,
    VDDA,
    VSWITCH,
    VDDIO_Q,
    VCCHIB,
    VDDIO,
    VDDIO_PAD,
    VCCD,
    VSSIO,
    VSSD,
    VSSIO_Q
);
    inout AMUXBUS_A;
    inout AMUXBUS_B;
    inout DRN_HVC;
    inout SRC_BDY_HVC;
    inout VDDIO;
    inout VDDIO_PAD;
    inout VDDIO_Q;
    inout VDDA;
    inout VCCD;
    inout VSWITCH;
    inout VCCHIB;
    inout VSSA;
    inout VSSD;
    inout VSSIO_Q;
    inout VSSIO;
endmodule

module sky130_ef_io__vssio_hvc_pad (
    AMUXBUS_A,
    AMUXBUS_B,
    DRN_HVC,
    SRC_BDY_HVC,
    VSSA,
    VDDA,
    VSWITCH,
    VDDIO_Q,
    VCCHIB,
    VDDIO,
    VCCD,
    VSSIO,
    VSSIO_PAD,
    VSSD,
    VSSIO_Q
);
    inout AMUXBUS_A;
    inout AMUXBUS_B;
    inout DRN_HVC;
    inout SRC_BDY_HVC;
    inout VDDIO;
    inout VDDIO_Q;
    inout VDDA;
    inout VCCD;
    inout VSWITCH;
    inout VCCHIB;
    inout VSSA;
    inout VSSD;
    inout VSSIO_Q;
    inout VSSIO;
    inout VSSIO_PAD;
endmodule
