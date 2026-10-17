package com.wiyuka.acceleratedrecoiling;

import com.mojang.logging.LogUtils;
import com.wiyuka.acceleratedrecoiling.command.ArCommand;
import net.neoforged.bus.api.IEventBus;
import net.neoforged.fml.ModContainer;
import net.neoforged.fml.common.Mod;
import net.neoforged.neoforge.common.NeoForge;
import org.slf4j.Logger;

@Mod(AcceleratedRecoiling.MODID)
public class AcceleratedRecoiling {
    public static final String MODID = "acceleratedrecoiling";
    public static final Logger LOGGER = LogUtils.getLogger();

    public AcceleratedRecoiling(IEventBus modEventBus, ModContainer modContainer) {
        NeoForge.EVENT_BUS.addListener(ArCommand::register);
    }
}
