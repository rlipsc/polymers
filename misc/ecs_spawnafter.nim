#[
  Simple ECS plugin for spawning a construction of entities after some delay.
]#

import polymorph

template defineSpawnAfter*(compOpts: ECSCompOptions, sysOpts: ECSSysOptions): untyped {.dirty.} =
  from times import epochTime

  registerComponents(compOpts):
    type
      SpawnAfter* = object
        startTime*: float
        duration*: float
        item*: ConstructionTemplate

  SpawnAfter.onAdd:
    curComponent.startTime = epochTime()

  defineSystem("spawnAfter", [SpawnAfter], sysOpts)

template addSpawnAfterSystem*: untyped {.dirty.} =
  makeSystemBody("spawnAfter"):
    start:
      let curTime = epochTime()
    all:
      if curTime - item.spawnAfter.startTime >= item.spawnAfter.duration:
        discard item.spawnAfter.item.construct
        item.entity.removeComponent SpawnAfter
