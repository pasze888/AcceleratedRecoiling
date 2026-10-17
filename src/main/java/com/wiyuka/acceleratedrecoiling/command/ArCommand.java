package com.wiyuka.acceleratedrecoiling.command;

import com.wiyuka.acceleratedrecoiling.natives.realtime.RealtimeNative;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;
import net.neoforged.neoforge.event.RegisterCommandsEvent;

/**
 * {@code /ar on|off|status} — flips the accelerated collision paths so the same
 * world, the same entities and the same JIT can be measured twice.
 */
public final class ArCommand {
    private ArCommand() {
    }

    public static void register(RegisterCommandsEvent event) {
        event.getDispatcher().register(Commands.literal("ar")
                .requires(Commands.hasPermission(Commands.LEVEL_GAMEMASTERS))
                .then(Commands.literal("on").executes(context -> switchTo(context.getSource(), true)))
                .then(Commands.literal("off").executes(context -> switchTo(context.getSource(), false)))
                .then(Commands.literal("status").executes(context -> {
                    context.getSource().sendSuccess(ArCommand::describe, false);
                    return 1;
                })));
    }

    private static int switchTo(CommandSourceStack source, boolean enabled) {
        RealtimeNative.setEnabled(enabled);
        source.sendSuccess(ArCommand::describe, true);
        return 1;
    }

    private static Component describe() {
        return Component.literal(RealtimeNative.isEnabled()
                ? "AcceleratedRecoiling ON (" + RealtimeNative.kernelName() + ")"
                : "AcceleratedRecoiling OFF (vanilla collisions)");
    }
}
