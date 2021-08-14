## Simple ECS plugin for spawning a construction of entities after some delay.

import polymorph

template defineSpawnAfter*(compOpts: ECSCompOptions): untyped {.dirty.} =
  from times import epochTime

  registerComponents(compOpts):
    type
      SpawnAfter* = object
        startTime*: float
        duration*: float
        item*: ConstructionTemplate

  SpawnAfter.onAdd:
    curComponent.startTime = epochTime()

template defineSpawnAfterSystem*(sysOpts: ECSSysOptions): untyped {.dirty.} =
  makeSystemOpts("spawnAfter", [SpawnAfter], sysOpts):
    let
      curTime = epochTime()

    all:
      if curTime - item.spawnAfter.startTime >= item.spawnAfter.duration:
        discard item.spawnAfter.item.construct
        entity.remove SpawnAfter
