<?php

namespace Liberu\Foundation\IdentityFilament\Resources\UserResource\Pages;

use Filament\Facades\Filament;
use Filament\Resources\Pages\CreateRecord;
use Liberu\Foundation\IdentityFilament\Resources\UserResource;
use Liberu\Foundation\Organizations\Models\Team;

/**
 * CLARTO overlay of the installed CreateUser page:
 * - the new user joins the team (tenant) it was created under, so it can reach the panel;
 * - it receives an e-mail to create its own password (App\Auth\AccessLink).
 */
class CreateUser extends CreateRecord
{
    protected static string $resource = UserResource::class;

    protected function afterCreate(): void
    {
        $team = Filament::getTenant();

        if ($team instanceof Team) {
            if (! $team->users()->whereKey($this->record->id)->exists()) {
                $team->users()->attach($this->record->id);
            }
            if ($this->record->current_team_id === null) {
                $this->record->forceFill(['current_team_id' => $team->id])->save();
            }
        }

        \App\Auth\AccessLink::notify(\App\Auth\AccessLink::send($this->record, invitation: true));
    }
}
