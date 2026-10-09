import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

import type {
  Routine,
  RoutineInput,
  RoutinePackageStamp,
  RoutineRequestCommit,
} from "../routines.ts";

/**
 * In-memory stand-in for the routine scheduler's persistence surface, used by
 * tests for features that sit beside routines (backups, packages, org library)
 * and only need create/list/update/remove semantics — never scheduling. The
 * real scheduler lives in the Jac harness (jac/harness/routines.jac).
 *
 * `file` mirrors the deleted RoutineManager's option: when given, mutations
 * persist as `{ routines }` JSON and a new instance reloads them, which is how
 * crash-recovery tests carry state across a restarted fixture.
 */
export class RoutineStub {
  private routines: Routine[] = [];
  private counter = 0;

  constructor(private readonly options: { file?: string } = {}) {
    if (options.file && existsSync(options.file)) {
      try {
        const disk = JSON.parse(readFileSync(options.file, "utf8")) as { routines?: Routine[] };
        this.routines = disk.routines ?? [];
        this.counter = this.routines.length;
      } catch {
        this.routines = [];
      }
    }
  }

  private persist(): void {
    if (!this.options.file) return;
    mkdirSync(dirname(this.options.file), { recursive: true });
    writeFileSync(this.options.file, JSON.stringify({ version: 1, routines: this.routines, runs: [] }));
  }

  create(input: RoutineInput, _request?: RoutineRequestCommit): Routine {
    this.counter += 1;
    const routine = {
      id: `routine-${this.counter}`,
      target: "bot",
      runOn: "maus",
      enabled: true,
      durationMinutes: 15,
      nextRunAt: null,
      createdAt: 1_000,
      updatedAt: 1_000,
      ...input,
    } as Routine;
    this.routines.unshift(routine);
    this.persist();
    return routine;
  }

  update(id: string, patch: Partial<RoutineInput>, _request?: RoutineRequestCommit): Routine | null {
    const routine = this.routines.find((candidate) => candidate.id === id);
    if (!routine) return null;
    Object.assign(routine, patch);
    routine.updatedAt += 1;
    this.persist();
    return routine;
  }

  remove(id: string, _request?: RoutineRequestCommit): boolean {
    const index = this.routines.findIndex((candidate) => candidate.id === id);
    if (index < 0) return false;
    this.routines.splice(index, 1);
    this.persist();
    return true;
  }

  /** Wire shape: the server-private installedPackage stamp never leaves the
   * scheduler, so listRoutines returns copies without it. */
  listRoutines(): Routine[] {
    return this.routines.map((routine) => {
      const { installedPackage: _installedPackage, ...rest } = routine;
      return rest;
    });
  }

  packageStamps(): Array<{ routineId: string; botId: string; enabled: boolean; stamp: RoutinePackageStamp }> {
    return this.routines
      .filter((routine) => routine.installedPackage)
      .map((routine) => ({
        routineId: routine.id,
        botId: routine.botId,
        enabled: routine.enabled,
        stamp: routine.installedPackage!,
      }));
  }

  stampInstalledPackage(id: string, stamp: RoutinePackageStamp): boolean {
    const routine = this.routines.find((candidate) => candidate.id === id);
    if (!routine) return false;
    routine.installedPackage = stamp;
    this.persist();
    return true;
  }
}
